defmodule Backplane.McpProtocolTest do
  use ExUnit.Case, async: true

  test "reports supported protocol versions" do
    assert Backplane.McpProtocol.protocol_version() == "2025-11-25"
    assert "2025-11-25" in Backplane.McpProtocol.supported_protocol_versions()
    assert "2025-06-18" in Backplane.McpProtocol.supported_protocol_versions()
  end

  test "negotiates unknown versions to latest supported version" do
    assert Backplane.McpProtocol.negotiate_version("1999-01-01") == "2025-11-25"
  end
end
