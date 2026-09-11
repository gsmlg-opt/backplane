defmodule Backplane.AiProtocol.TestKit do
  @moduledoc """
  Test support for `Backplane.AiProtocol`.

  Fixtures are independently authored raw protocol samples with explicit expected facts.
  """

  def protocol_package, do: :backplane_ai_protocol

  @doc "A deterministic OpenAI Responses non-streaming fixture and independent expectations."
  def openai_responses_non_stream do
    %{
      status: 200,
      body:
        ~S({"id":"resp_fixture_1","object":"response","status":"completed","output":[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"fixture output","annotations":[]}]}],"usage":{"input_tokens":11,"input_tokens_details":{"cached_tokens":3},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":18}}),
      expected: %{
        provider_request_id: "resp_fixture_1",
        protocol_terminal: :completed,
        input_tokens: 11,
        output_tokens: 7,
        cached_tokens: 3,
        reasoning_tokens: 2
      }
    }
  end

  @doc "A split-safe OpenAI Responses SSE fixture with trailing usage."
  def openai_responses_sse do
    [
      "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\r\n\r\n",
      "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture_stream\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"total_tokens\":7}}}\n\n"
    ]
  end
end
