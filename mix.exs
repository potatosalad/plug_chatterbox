defmodule PlugChatterbox.Mixfile do
  use Mix.Project

  def project do
    [app: :plug_chatterbox,
     version: "0.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger, :ranch, :chatterbox, :plug],
     mod: {PlugChatterbox.Application, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:chatterbox, "~> 0.4.0"},
     {:ranch, github: "ninenines/ranch", ref: "1.3.0", override: true, optional: true},
     {:plug, "~> 1.3.0"}]
  end
end
