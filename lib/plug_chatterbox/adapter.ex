defmodule Plug.Adapters.Chatterbox do
  @moduledoc """
  Adapter interface to the Chatterbox webserver.

  ## Options

  * `:ip` - the ip to bind the server to.
    Must be a tuple in the format `{x, y, z, w}`.

  * `:port` - the port to run the server.
    Defaults to 4000 (http) and 4040 (https).

  * `:acceptors` - the number of acceptors for the listener.
    Defaults to 100.

  * `:max_connections` - max number of connections supported.
    Defaults to `16_384`.

  * `:dispatch` - manually configure Chatterbox's dispatch.
    If this option is used, the given plug won't be initialized
    nor dispatched to (and doing so becomes the user's responsibility).

  * `:ref` - the reference name to be used.
    Defaults to `plug.HTTP` (http) and `plug.HTTPS` (https).
    This is the value that needs to be given on shutdown.

  * `:http2_settings` - Specifies chatterbox HTTP/2 options.

  * `:protocol_options` - Specifies remaining protocol options.

  All other options are given to the underlying transport.
  """

  # Made public with @doc false for testing.
  @doc false
  def args(scheme, plug, opts, chatterbox_options) do
    {chatterbox_options, non_keyword_options} =
      Enum.partition(chatterbox_options, &is_tuple(&1) and tuple_size(&1) == 2)

    chatterbox_options
    |> Keyword.put_new(:max_connections, 16_384)
    |> Keyword.put_new(:ref, build_ref(plug, scheme))
    |> Keyword.put_new(:dispatch, chatterbox_options[:dispatch] || dispatch_for(plug, opts))
    |> normalize_chatterbox_options(scheme)
    |> to_args(non_keyword_options)
  end

  @doc """
  Run chatterbox under http.

  ## Example

      # Starts a new interface
      Plug.Adapters.Chatterbox.http MyPlug, [], port: 80

      # The interface above can be shutdown with
      Plug.Adapters.Chatterbox.shutdown MyPlug.HTTP

  """
  @spec http(module(), Keyword.t, Keyword.t) ::
        {:ok, pid} | {:error, :eaddrinuse} | {:error, term}
  def http(plug, opts, chatterbox_options \\ []) do
    run(:http, plug, opts, chatterbox_options)
  end

  @doc """
  Run chatterbox under https.

  Besides the options described in the module documentation,
  this module also accepts all options defined in [the `ssl`
  erlang module] (http://www.erlang.org/doc/man/ssl.html),
  like keyfile, certfile, cacertfile, dhfile and others.

  The certificate files can be given as a relative path.
  For such, the `:otp_app` option must also be given and
  certificates will be looked from the priv directory of
  the given application.

  ## Example

      # Starts a new interface
      Plug.Adapters.Chatterbox.https MyPlug, [],
        port: 443,
        password: "SECRET",
        otp_app: :my_app,
        keyfile: "priv/ssl/key.pem",
        certfile: "priv/ssl/cert.pem",
        dhfile: "priv/ssl/dhparam.pem"

      # The interface above can be shutdown with
      Plug.Adapters.Chatterbox.shutdown MyPlug.HTTPS

  """
  @spec https(module(), Keyword.t, Keyword.t) ::
        {:ok, pid} | {:error, :eaddrinuse} | {:error, term}
  def https(plug, opts, chatterbox_options \\ []) do
    Application.ensure_all_started(:ssl)
    run(:https, plug, opts, chatterbox_options)
  end

  @doc """
  Shutdowns the given reference.
  """
  def shutdown(ref) do
    :ranch.stop_listener(ref)
  end

  @doc """
  Returns a child spec to be supervised by your application.

  ## Example

  Presuming your Plug module is named `MyRouter` you can add it to your
  supervision tree like so using this function:

      defmodule MyApp do
        use Application

        def start(_type, _args) do
          import Supervisor.Spec

          children = [
            Plug.Adapters.Chatterbox.child_spec(:http, MyRouter, [], [port: 4001])
          ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end
  """
  def child_spec(scheme, plug, opts, chatterbox_options \\ []) do
    [ref, nb_acceptors, trans_opts, proto_opts] = args(scheme, plug, opts, chatterbox_options)
    transport = case scheme do
      :http  -> :ranch_tcp
      :https -> :ranch_ssl
    end
    chatterbox_args = [ref, nb_acceptors, transport, trans_opts, :chatterbox_ranch_protocol, proto_opts]
    {
      {:ranch_listener_sup, ref},
      {:ranch, :start_listener, chatterbox_args},
      :permanent, :infinity, :supervisor, [:ranch_listener_sup]
    }
  end

  ## Helpers

  @protocol_options [:http2_settings, :plug, :plug_options]

  defp run(scheme, plug, opts, chatterbox_options) do
    case Application.ensure_all_started(:chatterbox) do
      {:ok, _} ->
        :ok
      {:error, {:chatterbox, _}} ->
        raise "could not start the chatterbox application. Please ensure it is listed " <>
              "as a dependency both in deps and application in your mix.exs"
    end
    transport = case scheme do
      :http  -> :ranch_tcp
      :https -> :ranch_ssl
      other  -> :erlang.error({:badarg, [other]})
    end
    [ref, nb_acceptors, trans_opts, proto_opts] = args(scheme, plug, opts, chatterbox_options)
    :ranch.start_listener(ref, nb_acceptors, transport, trans_opts, :chatterbox_ranch_protocol, proto_opts)
  end

  defp normalize_chatterbox_options(chatterbox_options, :http) do
    Keyword.put_new chatterbox_options, :port, 4000
  end

  defp normalize_chatterbox_options(chatterbox_options, :https) do
    assert_ssl_options(chatterbox_options)
    chatterbox_options = Keyword.put_new chatterbox_options, :port, 4040
    chatterbox_options = Enum.reduce [:keyfile, :certfile, :cacertfile, :dhfile], chatterbox_options, &normalize_ssl_file(&1, &2)
    chatterbox_options = Enum.reduce [:password], chatterbox_options, &to_char_list(&2, &1)
    chatterbox_options
  end

  defp to_args(opts, non_keyword_opts) do
    opts = Keyword.delete(opts, :otp_app)
    {ref, opts} = Keyword.pop(opts, :ref)
    {dispatch, opts} = Keyword.pop(opts, :dispatch)
    {acceptors, opts} = Keyword.pop(opts, :acceptors, 100)
    {protocol_options, opts} = Keyword.pop(opts, :protocol_options, [])

    dispatch = :plug_chatterbox_router.compile(dispatch)
    {extra_options, transport_options} = Keyword.split(opts, @protocol_options)
    env = Map.merge(Keyword.get(protocol_options, :env, %{}), %{
      dispatch: dispatch
    })
    protocol_options = Keyword.put(protocol_options, :env, env) ++ extra_options

    [ref, acceptors, non_keyword_opts ++ transport_options, protocol_options]
  end

  defp build_ref(plug, scheme) do
    Module.concat(plug, scheme |> to_string |> String.upcase)
  end

  defp dispatch_for(plug, opts) do
    opts = plug.init(opts)
    [{:_, [{:_, Plug.Adapters.Chatterbox.Handler, {plug, opts}}]}]
  end

  defp normalize_ssl_file(key, chatterbox_options) do
    value = chatterbox_options[key]

    cond do
      is_nil(value) ->
        chatterbox_options
      Path.type(value) == :absolute ->
        put_ssl_file chatterbox_options, key, value
      true ->
        put_ssl_file chatterbox_options, key, Path.expand(value, otp_app(chatterbox_options))
    end
  end

  defp assert_ssl_options(chatterbox_options) do
    unless Keyword.has_key?(chatterbox_options, :key) or
           Keyword.has_key?(chatterbox_options, :keyfile) do
      fail "missing option :key/:keyfile"
    end
    unless Keyword.has_key?(chatterbox_options, :cert) or
           Keyword.has_key?(chatterbox_options, :certfile) do
      fail "missing option :cert/:certfile"
    end
  end

  defp put_ssl_file(chatterbox_options, key, value) do
    value = to_char_list(value)
    unless File.exists?(value) do
      fail "the file #{value} required by SSL's #{inspect key} either does not exist, or the application does not have permission to access it"
    end
    Keyword.put(chatterbox_options, key, value)
  end

  defp otp_app(chatterbox_options) do
    if app = chatterbox_options[:otp_app] do
      Application.app_dir(app)
    else
      fail "to use a relative certificate with https, the :otp_app " <>
           "option needs to be given to the adapter"
    end
  end

  defp to_char_list(chatterbox_options, key) do
    if value = chatterbox_options[key] do
      Keyword.put chatterbox_options, key, to_char_list(value)
    else
      chatterbox_options
    end
  end

  defp fail(message) do
    raise ArgumentError, message: "could not start Chatterbox adapter, " <> message
  end
end
