defmodule Backplane.LLM.GoogleObserverIntegrationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Backplane.LLM.{AccessEvent, UsageAccumulator}

  @official_fixture Path.expand(
                      "../../../../../integrations/google-genai/fixtures/official/generate-content-recorded-response.json",
                      __DIR__
                    )

  test "official recorded response preserves MAX_TOKENS partial semantics and native counters" do
    wire = File.read!(@official_fixture)
    pid = UsageAccumulator.new(:google_generate_content_body)
    on_exit(fn -> UsageAccumulator.stop(pid) end)

    assert :ok = UsageAccumulator.scan_chunk(pid, wire)
    assert File.read!(@official_fixture) == wire

    snapshot = UsageAccumulator.snapshot(pid, 200)
    assert snapshot.finish_reason == "MAX_TOKENS"
    assert snapshot.input_tokens == 7
    assert snapshot.output_tokens == 149
    assert snapshot.reasoning_tokens == 48
    assert snapshot.metadata.protocol_observation.native_total == 204
    assert snapshot.partial
  end

  test "streaming GenerateContent uses the bounded Google observer" do
    access =
      conn(:post, "/v1beta/models/gemini:streamGenerateContent", "{}")
      |> AccessEvent.start("stream_generate", :google_generate_content)
      |> AccessEvent.mark_stream()

    on_exit(fn -> UsageAccumulator.stop(access.usage_acc) end)

    assert %{protocol: :google_generate_content} = Agent.get(access.usage_acc, & &1)

    wire =
      "data: " <>
        Jason.encode!(%{
          "responseId" => "google-stream-1",
          "candidates" => [
            %{
              "index" => 0,
              "finishReason" => "STOP",
              "content" => %{"parts" => [%{"text" => "done"}]}
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 13,
            "candidatesTokenCount" => 5,
            "thoughtsTokenCount" => 2,
            "cachedContentTokenCount" => 3,
            "totalTokenCount" => 20
          }
        }) <> "\n\n"

    UsageAccumulator.scan_chunk(access.usage_acc, wire)
    Agent.get(access.usage_acc, & &1)
    snapshot = UsageAccumulator.snapshot(access.usage_acc, 200)

    assert snapshot.input_tokens == 13
    assert snapshot.output_tokens == 5
    assert snapshot.reasoning_tokens == 2
    assert snapshot.cached_tokens == 3
    assert snapshot.provider_request_id == "google-stream-1"
    assert snapshot.protocol == :google_generate_content
    assert snapshot.metadata.protocol_observation.native_total == 20
    assert is_integer(snapshot.metadata.timing.first_content_ms)
    assert snapshot.stream_chunks == 1
    assert is_integer(snapshot.ttft_ms)
    assert is_integer(snapshot.stream_duration_ms)
  end

  test "non-streaming GenerateContent selects body observation" do
    access =
      conn(:post, "/v1beta/models/gemini:generateContent", "{}")
      |> AccessEvent.start("generate", :google_generate_content)
      |> AccessEvent.prepare_response_observation()

    on_exit(fn -> UsageAccumulator.stop(access.usage_acc) end)
    assert %{protocol: :google_generate_content_body} = Agent.get(access.usage_acc, & &1)

    UsageAccumulator.scan_chunk(
      access.usage_acc,
      Jason.encode!(%{
        "responseId" => "google-body-1",
        "candidates" => [
          %{
            "index" => 0,
            "finishReason" => "STOP",
            "content" => %{"parts" => [%{"text" => "done"}]}
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 8,
          "candidatesTokenCount" => 4,
          "totalTokenCount" => 12
        }
      })
    )

    Agent.get(access.usage_acc, & &1)
    snapshot = UsageAccumulator.snapshot(access.usage_acc, 200)
    assert snapshot.input_tokens == 8
    assert snapshot.output_tokens == 4
    assert snapshot.provider_request_id == "google-body-1"
    assert snapshot.protocol_terminal == :completed
    assert is_integer(snapshot.metadata.timing.first_content_ms)
  end

  test "countTokens selects isolated body observation" do
    access =
      conn(:post, "/v1beta/models/gemini:countTokens", "{}")
      |> AccessEvent.start("count_tokens", :google_generate_content)
      |> AccessEvent.prepare_response_observation()

    on_exit(fn -> UsageAccumulator.stop(access.usage_acc) end)
    assert %{protocol: :google_count_tokens_body} = Agent.get(access.usage_acc, & &1)

    UsageAccumulator.scan_chunk(access.usage_acc, Jason.encode!(%{"totalTokens" => 42}))
    Agent.get(access.usage_acc, & &1)
    snapshot = UsageAccumulator.snapshot(access.usage_acc, 200)

    assert snapshot.input_tokens == nil
    assert snapshot.output_tokens == nil
    assert snapshot.usage_complete == false
    assert snapshot.metadata.operation == %{name: "count_tokens", total_tokens: 42}
    assert snapshot.metadata.timing.first_content_ms == nil
    refute Map.has_key?(snapshot.metadata.protocol_observation, :count_tokens_total)
  end

  for {reason, terminal, transport} <- [
        {:cancelled, :cancelled, :cancelled},
        {:error, :incomplete, :failed}
      ],
      mode <- [:google_generate_content_body, :google_count_tokens_body] do
    test "#{mode} respects #{reason} after a complete JSON document" do
      pid = UsageAccumulator.new(unquote(mode))
      on_exit(fn -> UsageAccumulator.stop(pid) end)

      body =
        if unquote(mode) == :google_count_tokens_body do
          ~s({"totalTokens":3})
        else
          ~s({"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}})
        end

      UsageAccumulator.scan_chunk(pid, body)
      Agent.get(pid, & &1)
      snapshot = UsageAccumulator.snapshot(pid, 200, unquote(reason))
      assert snapshot.protocol_terminal == unquote(terminal)
      assert snapshot.metadata.protocol_observation.transport_terminal == unquote(transport)
      assert snapshot.partial
      refute snapshot.usage_complete
    end
  end

  test "Google observation queue saturation remains nonblocking and incomplete" do
    pid = UsageAccumulator.new(:google_generate_content, max_queue: 0)
    on_exit(fn -> UsageAccumulator.stop(pid) end)

    assert :ok = UsageAccumulator.scan_chunk(pid, "data: {}\n\n")

    snapshot = UsageAccumulator.snapshot(pid, 200)
    assert snapshot.observation_status == :incomplete
    assert snapshot.partial == true
    assert snapshot.metadata.observation.queue_saturated == true
  end

  test "transport failure overrides a previously observed content finish" do
    pid = UsageAccumulator.new(:google_generate_content)
    on_exit(fn -> UsageAccumulator.stop(pid) end)

    UsageAccumulator.scan_chunk(
      pid,
      "data: " <>
        Jason.encode!(%{
          "candidates" => [%{"index" => 0, "finishReason" => "STOP"}],
          "usageMetadata" => %{"promptTokenCount" => 2, "candidatesTokenCount" => 1}
        }) <> "\n\n"
    )

    Agent.get(pid, & &1)
    snapshot = UsageAccumulator.snapshot(pid, 200, :error)
    assert snapshot.protocol_terminal == :incomplete
    assert snapshot.partial == true
    assert snapshot.metadata.protocol_observation.transport_terminal == :failed
  end
end
