defmodule PlugChatterbox.Application do
  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    :application.set_env(:chatterbox, :stream_callback_mod, Plug.Adapters.Chatterbox.Stream)
    # Logger.add_translator({Plug.Adapters.Chatterbox.Translator, :translate})

    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: Test.Worker.start_link(arg1, arg2, arg3)
      # worker(Test.Worker, [arg1, arg2, arg3]),
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PlugChatterbox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

