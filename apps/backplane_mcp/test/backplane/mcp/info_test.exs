defmodule Backplane.MCP.InfoTest do
  use ExUnit.Case, async: true

  alias Backplane.MCP.Info

  test "declares backplane_mcp_protocol as the protocol application dependency" do
    applications = Application.spec(:backplane_mcp, :applications)

    assert :backplane_mcp_protocol in applications
  end

  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  test "keeps the legacy endpoint default separate from the package latest" do
    assert Info.protocol_version() == "2025-11-25"
    assert Info.supported_versions() == @legacy_versions
    assert Backplane.McpProtocol.Protocol.latest_version() == "2026-07-28"
    refute Backplane.McpProtocol.Protocol.latest_version() in Info.supported_versions()
  end

  for version <- @legacy_versions do
    test "negotiates legacy protocol version #{version}" do
      assert Info.negotiate_version(unquote(version)) == unquote(version)
    end
  end
end
