defmodule Backplane.AiProtocol.TestKitTest do
  use Backplane.AiProtocol.TestKit.Case, async: true

  test "depends on protocol without reverse dependency" do
    assert Backplane.AiProtocol.TestKit.protocol_package() == :backplane_ai_protocol
    assert Code.ensure_loaded?(Backplane.AiProtocol)
  end
end

