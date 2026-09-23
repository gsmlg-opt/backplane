defmodule Backplane.AiProtocol.Antigravity.ObserverTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.Antigravity.Observer

  test "observes wrapped multi-candidate native usage without changing the wire" do
    document = %{
      "response" => %{
        "responseId" => "response-1",
        "candidates" => [
          %{"index" => 0, "finishReason" => "STOP"},
          %{"index" => 1, "finishReason" => "MAX_TOKENS"}
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 6,
          "thoughtsTokenCount" => 2,
          "totalTokenCount" => 18
        }
      },
      "opaqueEnvelope" => %{"never" => "retained in facts"}
    }

    wire = "data: " <> Jason.encode!(document) <> "\n\n"

    facts =
      wire
      |> :binary.bin_to_list()
      |> Enum.reduce(Observer.new(), fn byte, state -> Observer.feed(state, <<byte>>) end)
      |> Observer.finish(:eof)
      |> Observer.facts()

    assert facts.implementation == Observer
    assert facts.source == :google_antigravity
    assert facts.transport_terminal == :eof
    assert facts.protocol_terminal == :incomplete
    assert facts.candidate_count == 2
    assert facts.input_tokens == 10
    assert facts.output_tokens == 6
    assert facts.reasoning_tokens == 2
    assert facts.native_total == 18
    refute inspect(facts) =~ "never"
    refute inspect(facts) =~ "retained in facts"
  end

  test "observes non-stream response and sanitizes wrapped provider errors" do
    success = %{
      "response" => %{
        "candidates" => [%{"index" => 0, "finishReason" => "STOP"}],
        "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 2}
      }
    }

    facts = Observer.observe_response(200, Jason.encode!(success))
    assert facts.source == :google_antigravity
    assert facts.protocol_terminal == :completed
    assert facts.usage_status == :complete

    failed =
      Observer.observe_response(
        429,
        Jason.encode!(%{
          "error" => %{
            "code" => 429,
            "status" => "RESOURCE_EXHAUSTED",
            "message" => "private account detail"
          }
        })
      )

    assert failed.protocol_terminal == :failed
    assert failed.error_type == "RESOURCE_EXHAUSTED"
    refute inspect(failed) =~ "private account detail"
  end

  test "transport errors, cancellation and observation budgets remain incomplete" do
    complete =
      "data: " <>
        Jason.encode!(%{
          "response" => %{
            "candidates" => [%{"index" => 0, "finishReason" => "STOP"}],
            "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
          }
        }) <>
        "\n\n"

    state = Observer.new() |> Observer.feed(complete)
    failed = state |> Observer.finish(:error) |> Observer.facts()
    cancelled = state |> Observer.finish(:cancelled) |> Observer.facts()

    assert failed.protocol_terminal == :incomplete
    assert failed.transport_terminal == :failed
    assert cancelled.protocol_terminal == :cancelled
    assert cancelled.transport_terminal == :cancelled

    oversized =
      Observer.new(max_total_bytes: 8)
      |> Observer.feed(String.duplicate("x", 9))
      |> Observer.facts()

    assert oversized.observation_status == :incomplete
    assert oversized.partial == true
  end

  test "STOP keeps observation open for repeated cumulative usage and the final tail" do
    documents = [
      %{"response" => %{"candidates" => [%{"index" => 0, "finishReason" => "STOP"}]}},
      %{
        "response" => %{
          "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 2}
        }
      },
      %{
        "response" => %{
          "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 2}
        }
      },
      %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }
    ]

    state =
      Enum.reduce(documents, Observer.new(), fn document, state ->
        Observer.feed(state, "data: " <> Jason.encode!(document) <> "\n\n")
      end)

    assert Observer.facts(state).transport_terminal == nil
    facts = state |> Observer.finish(:eof) |> Observer.facts()
    assert facts.transport_terminal == :eof
    assert facts.protocol_terminal == :completed
    assert facts.input_tokens == 10
    assert facts.output_tokens == 5
    assert facts.native_total == 15
  end

  test "observation budget exhaustion does not replace the actual transport outcome" do
    state = Observer.new(max_total_bytes: 8) |> Observer.feed(String.duplicate("x", 9))

    for {reason, transport, protocol} <- [
          {:eof, :eof, :incomplete},
          {:cancelled, :cancelled, :cancelled},
          {:error, :failed, :incomplete}
        ] do
      finished = Observer.finish(state, reason)
      facts = Observer.facts(finished)
      assert facts.transport_terminal == transport
      assert facts.protocol_terminal == protocol
      assert facts.observation_status == :incomplete
      assert Observer.finish(finished, :eof) == finished
    end
  end

  test "exhausting the event budget after STOP cannot claim protocol completion" do
    stop = %{"response" => %{"candidates" => [%{"index" => 0, "finishReason" => "STOP"}]}}
    wire = "data: " <> Jason.encode!(stop) <> "\n\n"

    facts =
      Observer.new(max_events: 1)
      |> Observer.feed(wire)
      |> Observer.feed("data: {}\n\n")
      |> Observer.finish(:eof)
      |> Observer.facts()

    assert facts.transport_terminal == :eof
    assert facts.protocol_terminal == :incomplete
    assert facts.observation_status == :incomplete
  end
end
