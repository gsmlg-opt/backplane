defmodule Backplane.MCP.InfoTest do
  use ExUnit.Case, async: true

  alias Backplane.MCP.Info

  test "declares backplane_mcp_protocol as the protocol application dependency" do
    applications = Application.spec(:backplane_mcp, :applications)

    assert :backplane_mcp_protocol in applications
  end

  test "advertises only versions implemented by the hub transport" do
    assert Info.protocol_version() == "2025-11-25"

    assert Info.supported_versions() == [
             "2025-11-25",
             "2025-06-18",
             "2025-03-26",
             "2024-11-05"
           ]

    refute Backplane.McpProtocol.Protocol.latest_version() in Info.supported_versions()
  end
end
