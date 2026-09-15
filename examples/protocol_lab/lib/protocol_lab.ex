defmodule ProtocolLab do
  @moduledoc """
  Minimal independent consumer for the AI protocol package boundary.
  """
end

defmodule ProtocolLab.CLI do
  @moduledoc false

  alias Backplane.AiProtocol.{OpenAIResponsesObserver, Request, Serialization}
  alias Backplane.AiProtocol.TestKit

  def main(_args) do
    {:ok, request} =
      Request.new(%{
        model: "fixture-model",
        input: [%{role: :user, content: [%{type: :text, text: "protocol lab"}]}]
      })

    {:ok, request_json} = Serialization.to_json(request)
    {:ok, decoded} = Serialization.from_json(request_json)

    fixture = TestKit.openai_responses_non_stream()
    facts = OpenAIResponsesObserver.observe_response(fixture.status, fixture.body)

    unless facts.input_tokens == fixture.expected.input_tokens and
             facts.protocol_terminal == fixture.expected.protocol_terminal do
      raise "fixture observation did not match independent expectations"
    end

    IO.puts("request_model=#{decoded["model"]}")
    IO.puts("observer=#{inspect(facts.implementation)}")

    IO.puts(
      "terminal=#{facts.protocol_terminal} input_tokens=#{facts.input_tokens} output_tokens=#{facts.output_tokens}"
    )
  end
end
