defmodule Backplane.AiProtocol.GoogleGenerateContentObserverTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.GoogleGenerateContentObserver, as: Observer

  test "observes fragmented UTF-8 JSON across arbitrary SSE chunks" do
    wire = event(response("STOP", usage(), text: "hello \u4e16\u754c"))

    facts =
      wire
      |> :binary.bin_to_list()
      |> Enum.map(&<<&1>>)
      |> observe(:eof)

    assert facts.protocol_terminal == :completed
    assert facts.transport_terminal == :eof
    assert facts.content_seen == true
    assert facts.content_finished == true
    assert facts.input_tokens == 11
    assert facts.output_tokens == 7
    assert facts.cached_tokens == 3
    assert facts.reasoning_tokens == 2
    assert facts.native_total == 21
    assert facts.provider_request_id == "resp-1"
  end

  test "handles CRLF and multiple frames in one feed" do
    wire =
      event(response(nil, nil, text: "first")) <>
        event(response("STOP", usage(), text: "second"))

    facts = observe([String.replace(wire, "\n", "\r\n")], :eof)

    assert facts.events_seen == 2
    assert facts.finish_reason == "STOP"
    assert facts.protocol_terminal == :completed
  end

  test "missing candidate indices remain stable across stream frames" do
    first = event(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "one"}]}}]})
    second = event(%{"candidates" => [%{"finishReason" => "STOP"}], "usageMetadata" => usage()})

    facts = observe([first, second], :eof)

    assert facts.candidate_count == 1
    assert facts.candidate_ambiguous == false
    assert facts.protocol_terminal == :completed
  end

  test "retains tail usage after content finish and replaces duplicate snapshots" do
    finished = event(response("STOP", nil, text: "done"))
    tail = event(response(nil, usage()))

    first = Observer.new() |> Observer.feed(finished) |> Observer.feed(tail)
    first_facts = Observer.facts(first)
    repeated = first |> Observer.feed(tail) |> Observer.finish(:eof) |> Observer.facts()

    assert first_facts.content_finished == true
    assert first_facts.protocol_terminal == nil
    assert repeated.input_tokens == 11
    assert repeated.output_tokens == 7
    assert repeated.native_total == 21
    assert repeated.protocol_terminal == :completed
  end

  test "unknown finish reason never implies success" do
    facts = observe([event(response("FUTURE_REASON", usage()))], :eof)

    assert facts.finish_reason == "FUTURE_REASON"
    assert facts.protocol_terminal == :incomplete
    assert facts.observation_status == :incomplete
    assert "unknown_finish_reason" in facts.diagnostics
  end

  test "EOF without a verified finish is incomplete even with usage" do
    facts = observe([event(response(nil, usage()))], :eof)

    assert facts.protocol_terminal == :incomplete
    assert facts.transport_terminal == :eof
    assert facts.usage_status == :complete
    assert "missing_verified_finish" in facts.diagnostics
  end

  test "transport failure and cancellation remain incomplete after content finish" do
    state = Observer.new() |> Observer.feed(event(response("STOP", usage())))

    failed = state |> Observer.finish(:error) |> Observer.facts()
    cancelled = state |> Observer.finish(:cancelled) |> Observer.facts()

    assert failed.protocol_terminal == :incomplete
    assert failed.transport_terminal == :failed
    assert cancelled.protocol_terminal == :cancelled
    assert cancelled.transport_terminal == :cancelled
  end

  test "records safety blocking without retaining messages or arbitrary payloads" do
    body =
      Jason.encode!(%{
        "responseId" => "blocked-1",
        "promptFeedback" => %{
          "blockReason" => "SAFETY",
          "blockReasonMessage" => "private safety explanation",
          "safetyRatings" => [
            %{"category" => "HARM_CATEGORY_HATE_SPEECH", "probability" => "HIGH"}
          ]
        },
        "private" => "do not retain"
      })

    facts = Observer.observe_response(200, body, [])

    assert facts.blocked == true
    assert facts.block_reason == "SAFETY"
    assert facts.protocol_terminal == :incomplete
    refute inspect(facts) =~ "private safety explanation"
    refute inspect(facts) =~ "do not retain"
  end

  test "records sanitized Google error status without retaining raw messages" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => 429,
          "status" => "RESOURCE_EXHAUSTED",
          "message" => "secret account detail",
          "details" => [%{"opaque" => "secret"}]
        }
      })

    facts = Observer.observe_response(429, body, [])

    assert facts.protocol_terminal == :failed
    assert facts.error_code == "429"
    assert facts.error_type == "RESOURCE_EXHAUSTED"
    refute inspect(facts) =~ "secret account detail"
    refute inspect(facts) =~ "opaque"
  end

  test "malformed and bounded observations never raise" do
    malformed = observe(["data: {not-json}\n\n"], :eof)
    oversized = observe([String.duplicate("x", 65)], :eof, max_total_bytes: 64)

    event_budgeted =
      observe([event(response(nil, nil)), event(response("STOP", usage()))], :eof, max_events: 1)

    time_budgeted =
      observe(
        [event(response("STOP", usage(), text: String.duplicate("x", 100_000)))],
        :eof,
        max_parse_time_us: 1
      )

    assert malformed.observation_status == :incomplete
    assert "invalid_event_json" in malformed.diagnostics
    assert oversized.input_truncated == true
    assert "response_bytes_exceeded" in oversized.diagnostics
    assert event_budgeted.observation_status == :incomplete
    assert "parse_event_budget_exceeded" in event_budgeted.diagnostics
    assert time_budgeted.parse_budget_exhausted == true
    assert time_budgeted.parse_time_us > 1
    assert "parse_time_budget_exceeded" in time_budgeted.diagnostics
  end

  test "multiple candidates retain aggregate usage and mark finish ambiguity" do
    document = %{
      "responseId" => "multi-1",
      "candidates" => [
        %{"index" => 0, "finishReason" => "STOP"},
        %{"index" => 1, "finishReason" => "MAX_TOKENS"}
      ],
      "usageMetadata" => usage()
    }

    facts = Observer.observe_response(200, Jason.encode!(document), [])

    assert facts.input_tokens == 11
    assert facts.output_tokens == 7
    assert facts.candidate_count == 2
    assert facts.candidate_ambiguous == true
    assert facts.observation_status == :incomplete
    assert Enum.map(facts.finish_reasons, & &1.reason) == ["STOP", "MAX_TOKENS"]
  end

  test "whitelists native numeric usage and modality details" do
    usage =
      usage()
      |> Map.put("promptTokensDetails", [
        %{"modality" => "TEXT", "tokenCount" => 9, "private" => "drop"},
        %{"modality" => "IMAGE", "tokenCount" => 2}
      ])
      |> Map.put("trafficType", "ON_DEMAND")

    facts = Observer.observe_response(200, Jason.encode!(response("STOP", usage)), [])

    assert facts.native_usage.prompt_tokens_details == [
             %{modality: "TEXT", token_count: 9},
             %{modality: "IMAGE", token_count: 2}
           ]

    refute inspect(facts.native_usage) =~ "private"
    refute inspect(facts.native_usage) =~ "ON_DEMAND"
  end

  test "countTokens total is operation metadata, never generation usage" do
    facts =
      Observer.observe_response(
        200,
        Jason.encode!(%{"totalTokens" => 123, "cachedContentTokenCount" => 8}),
        operation: :count_tokens
      )

    assert facts.source == :google_count_tokens
    assert facts.count_tokens_total == 123
    assert facts.input_tokens == nil
    assert facts.output_tokens == nil
    assert facts.native_total == nil
    assert facts.usage_status == :not_applicable
    assert facts.protocol_terminal == :completed
  end

  defp observe(chunks, reason, opts \\ []) do
    chunks
    |> Enum.reduce(Observer.new(opts), &Observer.feed(&2, &1))
    |> Observer.finish(reason)
    |> Observer.facts()
  end

  defp event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  defp response(reason, usage, opts \\ []) do
    candidate =
      %{"index" => 0, "content" => %{"parts" => [%{"text" => Keyword.get(opts, :text, "ok")}]}}
      |> maybe_put("finishReason", reason)

    %{"responseId" => "resp-1", "candidates" => [candidate]}
    |> maybe_put("usageMetadata", usage)
  end

  defp usage do
    %{
      "promptTokenCount" => 11,
      "candidatesTokenCount" => 7,
      "cachedContentTokenCount" => 3,
      "thoughtsTokenCount" => 2,
      "totalTokenCount" => 21
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
