require Logger

defmodule Plug.Adapters.Chatterbox.Stream do
  @moduledoc false

  @behaviour :h2_stream

  defstruct [
    ref: nil,
    env: nil,
    connection_pid: nil,
    stream_id: nil,
    stream_pid: nil,
    handle_pid: nil,
    req_data_ref: nil,
    req_data_timer_ref: nil,
    req_data_length: 0,
    req_data_is_fin: :nofin,
    req_data_buffer: <<>>,
    req_pid: nil
  ]

  @request Plug.Adapters.Chatterbox.Request

  def init(connection_pid, stream_id) do
    {:ok, ref, env} = fetch_env(connection_pid)
    stream = %__MODULE__{
      ref: ref,
      env: env,
      connection_pid: connection_pid,
      stream_id: stream_id,
      stream_pid: self()
    }
    # Logger.info("init(#{inspect stream})")
    pid = :proc_lib.spawn_link(__MODULE__, :proc_lib_hack, [stream])
    {:ok, pid}
  end

  def on_receive_request_headers(headers, pid) do
    # Logger.info("on_receive_request_headers(#{inspect headers}, #{inspect pid})")
    send(pid, {pid, {:recv_h, headers}})
    {:ok, pid}
  end

  def on_send_push_promise(headers, pid) do
    # Logger.info("on_send_push_promise(#{inspect headers}, #{inspect pid})")
    send(pid, {pid, {:send_pp, headers}})
    {:ok, pid}
  end

  def on_receive_request_data(data, pid) do
    # Logger.info("on_receive_request_data(#{inspect data}, #{inspect pid})")
    send(pid, {pid, {:recv_data, data}})
    {:ok, pid}
  end

  def on_request_end_stream(pid) do
    # Logger.info("on_request_end_stream(#{inspect pid})")
    send(pid, {pid, :recv_es})
    {:ok, pid}
  end

  # Stream loop.
  def proc_lib_hack(stream) do
    try do
      loop(%{stream | handle_pid: self()})
    catch
      _, :normal -> exit(:normal)
      _, :shutdown -> exit(:shutdown)
      _, reason = {:shutdown, _} -> exit(reason)
      _, reason -> exit({reason, :erlang.get_stacktrace()})
    end
  end

  def loop(stream=%{stream_pid: parent}) do
    receive do
      # System messages.
      {:EXIT, ^parent, reason} ->
        exit(reason)
      {:system, from, request} ->
        :sys.handle_system_msg(request, from, parent, __MODULE__, [], stream)
      # Messages pertaining to this stream.
      {pid, msg} when pid == self() ->
        loop(info(stream, msg))
      # Exit signal from children.
      msg = {:EXIT, _pid, _} ->
        exit(:shutdown)
        # down(stream, pid, msg)
      msg ->
        :error_logger.error_msg('Received stray message ~p.', [msg])
        loop(stream)
    end
  end

  def info(stream=%{req_pid: nil}, {:recv_h, headers}) do
    receive do
      {pid, msg = {:recv_data, _}} when pid == self() ->
        {:ok, req_pid} = @request.start_link(stream, headers, false, :nofin)
        stream = %{stream | req_pid: req_pid}
        info(stream, msg)
      {pid, msg = :recv_es} when pid == self() ->
        {:ok, req_pid} = @request.start_link(stream, headers, false, {:fin, 0})
        stream = %{stream | req_pid: req_pid}
        info(stream, msg)
    after
      0 ->
        {:ok, req_pid} = @request.start_link(stream, headers, false, :nofin)
        %{stream | req_pid: req_pid}
    end
  end
  def info(stream=%{req_pid: nil}, {:send_pp, headers}) do
    receive do
      {pid, msg = :recv_es} when pid == self() ->
        {:ok, req_pid} = @request.start_link(stream, headers, true, {:fin, 0})
        stream = %{stream | req_pid: req_pid}
        info(stream, msg)
    after
      0 ->
        {:ok, req_pid} = @request.start_link(stream, headers, true, :nofin)
        %{stream | req_pid: req_pid}
    end
  end
  def info(stream=%{req_data_ref: nil, req_data_buffer: buffer}, {:recv_data, data}) do
    %{stream | req_data_buffer: << buffer :: binary, data :: binary >>}
  end
  def info(stream=%{req_data_length: length, req_data_buffer: buffer}, {:recv_data, data})
      when (byte_size(buffer) + byte_size(data)) < length do
    %{stream | req_data_buffer: << buffer :: binary, data :: binary >>}
  end
  def info(stream=%{req_pid: pid, req_data_ref: ref, req_data_is_fin: is_fin, req_data_timer_ref: tref, req_data_buffer: buffer}, {:recv_data, data}) do
    :ok = :erlang.cancel_timer(tref, [async: true, info: false])
    send(pid, {:request_body, ref, is_fin, << buffer :: binary, data :: binary >>})
    %{stream | req_data_ref: nil, req_data_timer_ref: nil, req_data_buffer: <<>>}
  end
  def info(stream=%{req_data_ref: nil, req_data_buffer: buffer}, :recv_es) do
    %{stream | req_data_is_fin: {:fin, byte_size(buffer)}}
  end
  def info(stream=%{req_pid: pid, req_data_ref: ref, req_data_timer_ref: tref, req_data_buffer: buffer}, :recv_es) do
    :ok = :erlang.cancel_timer(tref, [async: true, info: false])
    is_fin = {:fin, byte_size(buffer)}
    send(pid, {:request_body, ref, is_fin, buffer})
    %{stream | req_data_ref: nil, req_data_timer_ref: nil, req_data_buffer: <<>>, req_data_is_fin: is_fin}
  end
  # Request body, body buffered large enough or complete.
  def info(stream=%{req_pid: pid, req_data_is_fin: is_fin = {:fin, _}, req_data_buffer: data}, {:read_body, ref, length, _})
      when byte_size(data) >= length do
    send(pid, {:request_body, ref, is_fin, data})
    %{stream | req_body_buffer: <<>>}
  end
  # Request body, not enough to send yet.
  def info(stream, {:read_body, ref, length, period}) do
    tref = :erlang.send_after(period, self(), {self(), {:read_body_timeout, ref}})
    %{stream | req_data_ref: ref, req_data_timer_ref: tref, req_data_length: length}
  end
  # Request body reading timeout; send what we have so far.
  def info(stream=%{req_pid: pid, req_data_ref: ref, req_data_is_fin: is_fin, req_data_buffer: data}, {:read_body_timeout, ref}) do
    send(pid, {:request_body, ref, is_fin, data})
    %{stream | req_data_ref: nil, req_data_timer_ref: nil, req_data_buffer: <<>>}
  end
  # Request body reading expired timeout; ignore.
  def info(stream, {:read_body_timeout, _}) do
    stream
  end

  # System callbacks.
  def system_continue(_, _, stream),
    do: loop(stream)

  def system_terminate(reason, _, _, _),
    do: exit(reason)

  def system_code_change(misc, _, _, _),
    do: {:ok, misc}

  defp fetch_env(pid) do
    with {:dictionary, dictionary} <- :erlang.process_info(pid, :dictionary),
         [_, pid, :ranch_sup | _]  <- Keyword.fetch!(dictionary, :"$ancestors"),
         {{_, ref}, ^pid, _, _}    <- List.keyfind(:supervisor.which_children(:ranch_sup), pid, 1),
         protocol_options          <- :ranch.get_protocol_options(ref),
         env                       <- Keyword.fetch!(protocol_options, :env) do
      {:ok, ref, env}
    else _ ->
      :error
    end
  end

  # defp fetch_plug(pid) do
  #   with {:dictionary, dictionary} <- :erlang.process_info(pid, :dictionary),
  #        [_, pid, :ranch_sup | _]  <- Keyword.fetch!(dictionary, :"$ancestors"),
  #        {{_, ref}, ^pid, _, _}    <- List.keyfind(:supervisor.which_children(:ranch_sup), pid, 1),
  #        protocol_options          <- :ranch.get_protocol_options(ref),
  #        plug                      <- Keyword.fetch!(protocol_options, :plug),
  #        plug_options              <- Keyword.fetch!(protocol_options, :plug_options) do
  #     {:ok, ref, plug, plug_options}
  #   else _ ->
  #     :error
  #   end
  # end

end
