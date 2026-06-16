defmodule Backplane.MCP.InfoTest do
  use ExUnit.Case, async: true

  alias Backplane.MCP.Info
  alias Backplane.McpProtocol

  test "declares the shared protocol package as an application dependency" do
    assert :backplane_mcp_protocol in Application.spec(:backplane_mcp, :applications)
  end

  test "uses the shared MCP protocol package for version metadata" do
    assert Info.protocol_version() == McpProtocol.protocol_version()
    assert Info.supported_versions() == McpProtocol.supported_protocol_versions()
  end
end
