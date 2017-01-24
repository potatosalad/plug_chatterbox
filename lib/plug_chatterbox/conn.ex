defmodule Plug.Adapters.Chatterbox.Conn do
  @moduledoc false

  @behaviour Plug.Conn.Adapter

  @request Plug.Adapters.Chatterbox.Request

  def conn(req=%{host: host, port: port, method: method, path: path, headers: headers, peer: peer = {remote_ip, _}, qs: qs, scheme: scheme}) do
    %Plug.Conn{
      adapter: {__MODULE__, req},
      host: host,
      method: method,
      owner: self(),
      path_info: split_path(path),
      peer: peer,
      port: port,
      remote_ip: remote_ip,
      query_string: qs,
      req_headers: headers,
      request_path: path,
      scheme: String.to_atom(scheme)
    }
  end

  def send_resp(req, status, headers, body) do
    headers = List.keystore(headers, ":status", 0, {":status", Integer.to_string(status)})
    req = @request.reply(req, headers, body)
    {:ok, nil, req}
  end

  def send_file(req, status, headers, path, offset, length) do
    headers = List.keystore(headers, ":status", 0, {":status", Integer.to_string(status)})
    %File.Stat{type: :regular, size: size} = File.stat!(path)

    length =
      cond do
        length == :all -> size
        is_integer(length) -> length
      end

    body = {:sendfile, offset, length, path}

    req = @request.reply(req, headers, body)
    {:ok, nil, req}
  end

  def send_chunked(req, status, headers) do
    headers = List.keystore(headers, ":status", 0, {":status", Integer.to_string(status)})
    req = @request.stream_reply(req, headers)
    {:ok, nil, req}
  end

  def chunk(req, body) do
    @request.stream_body(req, body)
  end

  def read_req_body(req, opts \\ []) do
    @request.read_body(req, opts)
  end

  def parse_req_multipart(req, opts, callback) do
    # # We need to remove the length from the list
    # # otherwise chatterbox will attempt to load the
    # # whole length at once.
    # {limit, opts} = Keyword.pop(opts, :length, 8_000_000)

    # # We need to construct the header opts using defaults here,
    # # since once opts are passed chatterbox defaults are not applied anymore.
    # {headers_opts, opts} = Keyword.pop(opts, :headers, [])
    # headers_opts = headers_opts ++ [length: 64_000, read_length: 64_000, read_timeout: 5000]

    # {:ok, limit, acc, req} = parse_multipart(:cowboy_req.read_part(req, headers_opts), limit, opts, headers_opts, [], callback)

    # params = Enum.reduce(acc, %{}, &Plug.Conn.Query.decode_pair/2)

    # if limit > 0 do
    #   {:ok, params, req}
    # else
    #   {:more, params, req}
    # end
  end

  ## Helpers

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    for segment <- segments, segment != "", do: segment
  end

end