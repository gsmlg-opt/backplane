defmodule McpServerConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :mcp_server_consumer, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    protocol =
      case System.get_env("MCP_PROTOCOL_PATH") do
        nil -> {:backplane_mcp_protocol, "== " <> System.fetch_env!("MCP_PROTOCOL_VERSION")}
        path -> {:backplane_mcp_protocol, path: path}
      end

    [protocol, {:plug, "~> 1.18"}, {:gaoxy_http, "~> 0.12.1"}]
  end
end
