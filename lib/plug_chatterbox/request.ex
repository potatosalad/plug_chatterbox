defmodule Plug.Adapters.Chatterbox.Request do
  @moduledoc false

  defstruct [
    ref: nil,
    pid: nil,
    handle_pid: nil,
    stream_id: nil,
    stream_pid: nil,
    connection_pid: nil,
    peer: nil,
    method: nil,
    version: nil,
    scheme: nil,
    host: nil,
    port: nil,
    path: nil,
    qs: nil,
    headers: nil,
    has_body: false,
    has_read_body: false,
    body_length: nil,
    push_promise: false,
    host_info: nil,
    path_info: nil,
    bindings: nil
  ]

  def start_link(%{ref: ref, env: env, handle_pid: handle_pid, stream_id: stream_id, stream_pid: stream_pid, connection_pid: connection_pid}, headers, push_promise, is_fin) do
    {:ok, peer} = :h2_connection.get_peer(connection_pid)
    {_, authority} = List.keyfind(headers, ":authority", 0, List.keyfind(headers, "host", 0))
    {_, method} = List.keyfind(headers, ":method", 0)
    {_, fullpath} = List.keyfind(headers, ":path", 0)
    {_, scheme} = List.keyfind(headers, ":scheme", 0)
    {path, qs} = parse_fullpath(fullpath)
    {host, port} = parse_authority(authority)
    port =
      if is_nil(port) do
        case scheme do
          "http"  -> 80
          "https" -> 443
        end
      else
        port
      end
    has_body =
      if is_fin == :nofin do
        true
      else
        false
      end
    body_length =
      case is_fin do
        {:fin, body_length} ->
          body_length
        :nofin ->
          nil
      end
    req = %__MODULE__{
      ref: ref,
      handle_pid: handle_pid,
      stream_id: stream_id,
      stream_pid: stream_pid,
      connection_pid: connection_pid,
      peer: peer,
      method: method,
      version: :"HTTP/2",
      scheme: scheme,
      host: host,
      port: port,
      path: path,
      qs: qs,
      headers: headers,
      has_body: has_body,
      body_length: body_length,
      push_promise: push_promise
    }
    pid = :proc_lib.spawn_link(__MODULE__, :proc_lib_hack, [req, env])
    {:ok, pid}
  end

  def read_body(req, opts \\ [])
  def read_body(req=%{has_body: false}, _),
    do: {:ok, <<>>, req}
  def read_body(req=%{has_read_body: true}, _),
    do: {:ok, <<>>, req}
  def read_body(req=%{handle_pid: pid}, opts) do
    length = Keyword.get(opts, :length, 8_000_000)
    period = Keyword.get(opts, :period, 15_000)
    timeout = Keyword.get(opts, :timeout, period + 1_000)
    ref = :erlang.make_ref()
    send(pid, {pid, {:read_body, ref, length, period}})
    receive do
      {:request_body, ^ref, :nofin, body} ->
        {:more, body, req}
      {:request_body, ^ref, {:fin, body_length}, body} ->
        {:ok, body, set_body_length(req, body_length)}
    after
      timeout ->
        exit(:timeout)
    end
  end

  def set_body_length(req=%{headers: headers}, body_length) do
    headers = List.keystore(headers, "content-length", 0, {"content-length", :erlang.integer_to_binary(body_length)})
    %{req | headers: headers, body_length: body_length, has_read_body: true}
  end

  def reply(req=%{connection_pid: connection_pid, stream_id: stream_id}, headers, {:sendfile, offset, length, path}) do
    :h2_connection.send_headers(connection_pid, stream_id, :lists.usort(headers))
    sendfile(req, path, offset, length)
    req
  end
  def reply(req, headers, body) when is_list(body) do
    reply(req, headers, :erlang.iolist_to_binary(body))
  end
  def reply(req=%{connection_pid: connection_pid, stream_id: stream_id}, headers, body) do
    :h2_connection.send_headers(connection_pid, stream_id, :lists.usort(headers))
    :h2_connection.send_body(connection_pid, stream_id, body, [send_end_stream: true])
    req
  end

  def stream_body(req, body, send_end_stream \\ false)
  def stream_body(req, body, send_end_stream) when is_list(body) do
    stream_body(req, :erlang.iolist_to_binary(body), send_end_stream)
  end
  def stream_body(%{connection_pid: connection_pid, stream_id: stream_id}, body, send_end_stream) do
    :h2_connection.send_body(connection_pid, stream_id, body, [send_end_stream: send_end_stream])
    :ok
  end

  def stream_reply(req=%{connection_pid: connection_pid, stream_id: stream_id}, headers) do
    :h2_connection.send_headers(connection_pid, stream_id, :lists.usort(headers))
    req
  end

  ## Helpers

  defp sendfile(req, filename, offset, bytes) when is_list(filename) or is_atom(filename) or is_binary(filename) do
    chunk_size = 16384
    case :file.open(filename, [:read, :raw, :binary]) do
      {:ok, raw_file} ->
        case offset do
          0 -> :ok
          _ -> :file.position(raw_file, {:bof, offset})
        end
        try do
          sendfile_loop(req, raw_file, bytes, 0, chunk_size)
        after
          :ok = :file.close(raw_file)
        end
      error = {:error, _reason} ->
        error
    end
  end
  defp sendfile(req, raw_file, offset, bytes) do
    chunk_size = 16384
    initial =
      case :file.position(raw_file, {:cur, 0}) do
        {:ok, ^offset} ->
          offset
        {:ok, initial} ->
          {:ok, _} = :file.position(raw_file, {:bof, offset})
          initial
      end
    case sendfile_loop(req, raw_file, bytes, 0, chunk_size) do
      result = {:ok, _sent} ->
        {:ok, _} = :file.position(raw_file, {:bof, initial})
        result
      error = {:error, _reason} ->
        error
    end
  end

  defp sendfile_loop(req, _raw_file, sent, sent, _chunk_size) do
    :h2_connection.send_body(req.connection_pid, req.stream_id, <<>>, [send_end_stream: true])
    {:ok, sent}
  end
  defp sendfile_loop(req, raw_file, bytes, sent, chunk_size) do
    read_size = read_size(bytes, sent, chunk_size)
    case :file.read(raw_file, read_size) do
      {:ok, iodata} ->
        length = :erlang.iolist_size(iodata)
        is_last_frame = (bytes - sent - length) <= 0
        result =
          if is_last_frame do
            :h2_connection.send_body(req.connection_pid, req.stream_id, iodata, [send_end_stream: true])
          else
            :h2_connection.send_body(req.connection_pid, req.stream_id, iodata, [send_end_stream: false])
          end
        case result do
          :ok when is_last_frame == false ->
            sent = length + sent
            sendfile_loop(req, raw_file, bytes, sent, chunk_size)
          :ok when is_last_frame == true ->
            sent = length + sent
            {:ok, sent}
          error = {:error, _reason} ->
            error
        end
      :eof ->
        :h2_connection.send_body(req.connection_pid, req.stream_id, <<>>, [send_end_stream: true])
        {:ok, sent}
      error = {:error, _reason} ->
        error
    end
  end

  defp read_size(0, _sent, chunk_size),
    do: chunk_size
  defp read_size(bytes, sent, chunk_size),
    do: min(bytes - sent, chunk_size)

  # Request execution.
  def proc_lib_hack(req, env) do
    try do
      {:ok, _req} = execute(%{req | pid: self()}, env, [:plug_chatterbox_router, :plug_chatterbox_handler])
      exit(:normal)
    catch
      _, :normal -> exit(:normal)
      _, :shutdown -> exit(:shutdown)
      _, reason = {:shutdown, _} -> exit(reason)
      _, reason -> exit({reason, :erlang.get_stacktrace()})
    end
  end

  defp execute(req, env, [middleware | rest]) do
    # require Logger
    # Logger.info("#{inspect middleware}.execute(#{inspect req}, #{inspect env})")
    case middleware.execute(req, env) do
      {:ok, req, env} ->
        execute(req, env, rest)
      {:stop, status, req} ->
        headers = [{":status", Integer.to_string(status)}]
        :h2_connection.send_headers(req.connection_pid, req.stream_id, headers, [send_end_stream: true])
        {:ok, req}
    end
  end
  defp execute(req, _env, []) do
    {:ok, req}
  end

  # Originally from cowlib

  defmacro lowercase(c) do
    quote do
      case unquote(c) do
        ?A -> ?a
        ?B -> ?b
        ?C -> ?c
        ?D -> ?d
        ?E -> ?e
        ?F -> ?f
        ?G -> ?g
        ?H -> ?h
        ?I -> ?i
        ?J -> ?j
        ?K -> ?k
        ?L -> ?l
        ?M -> ?m
        ?N -> ?n
        ?O -> ?o
        ?P -> ?p
        ?Q -> ?q
        ?R -> ?r
        ?S -> ?s
        ?T -> ?t
        ?U -> ?u
        ?V -> ?v
        ?W -> ?w
        ?X -> ?x
        ?Y -> ?y
        ?Z -> ?z
        _  -> unquote(c)
      end
    end
  end

  defmacro lower(binary) do
    quote do
      for << c <- unquote(binary) >>, into: <<>>, do: << lowercase(c) >>
    end
  end

  defmacro lower(function, c, rest, acc) do
    quote bind_quoted: [function: function, c: c, rest: rest, acc: acc] do
      case c do
        ?A -> function.(rest, << acc :: binary, ?a >>)
        ?B -> function.(rest, << acc :: binary, ?b >>)
        ?C -> function.(rest, << acc :: binary, ?c >>)
        ?D -> function.(rest, << acc :: binary, ?d >>)
        ?E -> function.(rest, << acc :: binary, ?e >>)
        ?F -> function.(rest, << acc :: binary, ?f >>)
        ?G -> function.(rest, << acc :: binary, ?g >>)
        ?H -> function.(rest, << acc :: binary, ?h >>)
        ?I -> function.(rest, << acc :: binary, ?i >>)
        ?J -> function.(rest, << acc :: binary, ?j >>)
        ?K -> function.(rest, << acc :: binary, ?k >>)
        ?L -> function.(rest, << acc :: binary, ?l >>)
        ?M -> function.(rest, << acc :: binary, ?m >>)
        ?N -> function.(rest, << acc :: binary, ?n >>)
        ?O -> function.(rest, << acc :: binary, ?o >>)
        ?P -> function.(rest, << acc :: binary, ?p >>)
        ?Q -> function.(rest, << acc :: binary, ?q >>)
        ?R -> function.(rest, << acc :: binary, ?r >>)
        ?S -> function.(rest, << acc :: binary, ?s >>)
        ?T -> function.(rest, << acc :: binary, ?t >>)
        ?U -> function.(rest, << acc :: binary, ?u >>)
        ?V -> function.(rest, << acc :: binary, ?v >>)
        ?W -> function.(rest, << acc :: binary, ?w >>)
        ?X -> function.(rest, << acc :: binary, ?x >>)
        ?Y -> function.(rest, << acc :: binary, ?y >>)
        ?Z -> function.(rest, << acc :: binary, ?z >>)
        c  -> function.(rest, << acc :: binary, c  >>)
      end
    end
  end

  defmacro is_alpha(c) do
    quote do
      unquote(c) in (?a..?z) or unquote(c) in (?A..?Z)
    end
  end

  defmacro is_digit(c) do
    quote do
      unquote(c) in (?0..?9)
    end
  end

  defmacro is_hex(c) do
    quote do
      is_digit(unquote(c)) or unquote(c) in (?a..?f) or unquote(c) in (?A..?F)
    end
  end

  defmacro is_uri_sub_delims(c) do
    quote do
      unquote(c) in [?!, ?$, ?&, ?', ?(, ?), ?*, ?+, ?,, ?;, ?=]
    end
  end

  defmacro is_uri_unreserved(c) do
    quote do
      is_alpha(unquote(c)) or is_digit(unquote(c)) or unquote(c) in [?-, ?., ?_, ?~]
    end
  end

  defp parse_authority(<< ?[, r :: bits >>),
    do: parse_ipv6_address(r, << ?[ >>)
  defp parse_authority(authority),
    do: parse_reg_name(authority, <<>>)

  defp parse_ipv6_address(<< ?] >>, ip),
    do: {<< ip :: binary, ?] >>, nil}
  defp parse_ipv6_address(<< ?], ?:, port :: bits >>, ip),
    do: {<< ip :: binary, ?] >>, :erlang.binary_to_integer(port)}
  defp parse_ipv6_address(<< c, r :: bits >>, ip) when is_hex(c) or c in [?:, ?.],
    do: lower((&parse_ipv6_address/2), c, r, ip)

  defp parse_reg_name(<<>>, name),
    do: {name, nil}
  defp parse_reg_name(<< ?:, port :: bits >>, name),
    do: {name, :erlang.binary_to_integer(port)}
  defp parse_reg_name(<< c, r :: bits >>, name) when is_uri_unreserved(c) or is_uri_sub_delims(c),
    do: lower((&parse_reg_name/2), c, r, name)

  defp parse_fullpath(fullpath),
    do: parse_fullpath(fullpath, <<>>)

  defp parse_fullpath(<<>>, path),
    do: {path, <<>>}
  defp parse_fullpath(<< ?#, _ :: bits >>, path),
    do: {path, <<>>}
  defp parse_fullpath(<< ??, qs :: bits >>, path),
    do: parse_fullpath_query(qs, path, <<>>)
  defp parse_fullpath(<< c, rest :: bits >>, so_far),
    do: parse_fullpath(rest, << so_far :: binary, c >>)

  defp parse_fullpath_query(<<>>, path, query),
    do: {path, query}
  defp parse_fullpath_query(<< ?#, _ :: bits >>, path, query),
    do: {path, query}
  defp parse_fullpath_query(<< c, rest :: bits >>, path, so_far),
    do: parse_fullpath_query(rest, path, << so_far :: binary, c >>)

end
