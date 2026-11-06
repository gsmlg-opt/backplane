defmodule ResponsesWebsocketConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :responses_websocket_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:backplane_ai_protocol, path: System.fetch_env!("AI_PROTOCOL_PACKAGE_PATH")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
