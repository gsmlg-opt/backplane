defmodule Backplane.AiProtocol.TestKitTest do
  use Backplane.AiProtocol.TestKit.Case, async: true

  test "depends on protocol without reverse dependency" do
    assert Backplane.AiProtocol.TestKit.protocol_package() == :backplane_ai_protocol
    assert Code.ensure_loaded?(Backplane.AiProtocol)
  end

  test "fixture is raw and has an independent expected projection" do
    fixture = Backplane.AiProtocol.TestKit.openai_responses_non_stream()
    assert fixture.status == 200
    assert fixture.expected.input_tokens == 11
    assert Jason.decode!(fixture.body)["id"] == "resp_fixture_1"
  end
end
