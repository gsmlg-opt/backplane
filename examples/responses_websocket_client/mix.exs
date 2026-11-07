defmodule Backplane.ResponsesWebSocketClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_responses_websocket_client,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:http_web_socket, "== 1.0.0-rc.5"},
        {:backplane_ai_protocol, path: System.fetch_env!("AI_PROTOCOL_PACKAGE_PATH")}
      ]
    ]
  end

  def application do
    # OTP SSL is only the loopback test peer; the client uses HTTP.WebSocket TLS.
    [extra_applications: [:logger] ++ if(Mix.env() == :test, do: [:ssl], else: [])]
  end
end
