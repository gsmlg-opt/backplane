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

  test "custom Responses fixture projects patch, JavaScript and namespaced JSON independently" do
    fixture = Backplane.AiProtocol.TestKit.openai_responses_custom_tools()

    assert {:ok, response} =
             Backplane.AiProtocol.Codec.decode_response(
               :openai_responses,
               fixture.status,
               [],
               fixture.body
             )

    assert Enum.map(response.output, fn block ->
             Map.take(block.tool_call, [:id, :name, :raw_arguments])
           end) == fixture.expected
  end
end
