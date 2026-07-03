defmodule Backplane.MCP.InfoTest do
  use ExUnit.Case, async: true

  alias Backplane.MCP.Info

  test "declares backplane_mcp_protocol as the protocol application dependency" do
    applications = Application.spec(:backplane_mcp, :applications)

    assert :backplane_mcp_protocol in applications
  end

  test "uses Backplane.McpProtocol for version metadata" do
    assert Info.protocol_version() == Backplane.McpProtocol.Protocol.latest_version()
    assert Info.supported_versions() == Backplane.McpProtocol.Protocol.supported_versions()
  end
end
