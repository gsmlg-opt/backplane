defmodule Backplane.Transport.VersionHeader do
  @moduledoc """
  Plug that adds `X-Backplane-Version` and `X-MCP-Protocol-Version` response
  headers to every response. This lets clients detect server version and
  protocol compatibility without parsing the initialize response.
  """

  @behaviour Plug

  @app_version Mix.Project.config()[:version]
  @mcp_protocol_version "2025-03-26"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("x-backplane-version", @app_version)
    |> Plug.Conn.put_resp_header("x-mcp-protocol-version", @mcp_protocol_version)
  end
end
