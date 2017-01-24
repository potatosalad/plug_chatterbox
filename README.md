# PlugChatterbox

This is an experimental plug adapter for [chatterbox](https://github.com/joedevivo/chatterbox).

## Installation

  1. Add `plug_chatterbox` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:plug_chatterbox, github: "potatosalad/plug_chatterbox"}]
    end
    ```

  2. Ensure `plug_chatterbox` is started before your application:

    ```elixir
    def application do
      [applications: [:plug_chatterbox]]
    end
    ```

## Sample Application

### Plug

A sample application with plug is available at
https://github.com/potatosalad/plug_chatterbox_example

### Phoenix

In order to use Phoenix, the [phoenix_chatterbox]
(https://github.com/potatosalad/phoenix_chatterbox) application is required.

A sample application with plug is available at
https://github.com/potatosalad/phoenix_chatterbox_example
