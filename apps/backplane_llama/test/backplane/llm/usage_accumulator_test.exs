defmodule Backplane.LLM.UsageAccumulatorTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.UsageAccumulator

  describe "scan_chunk/2 + get_tokens/1" do
    test "extracts input_tokens from anthropic message_start event" do
      pid = UsageAccumulator.new()

      chunk =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25,\"output_tokens\":0}}}\n\n"

      UsageAccumulator.scan_chunk(pid, chunk)
      assert {25, 0} = UsageAccumulator.get_tokens(pid)
    end

    test "extracts output_tokens from anthropic message_delta event" do
      pid = UsageAccumulator.new()

      chunk1 =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n"

      chunk2 = "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":42}}\n\n"
      UsageAccumulator.scan_chunk(pid, chunk1)
      UsageAccumulator.scan_chunk(pid, chunk2)
      assert {10, 42} = UsageAccumulator.get_tokens(pid)
    end

    test "extracts prompt_tokens and completion_tokens from openai chunk" do
      pid = UsageAccumulator.new()
      chunk = "data: {\"usage\":{\"prompt_tokens\":15,\"completion_tokens\":30}}\n\n"
      UsageAccumulator.scan_chunk(pid, chunk)
      assert {15, 30} = UsageAccumulator.get_tokens(pid)
    end

    test "ignores chunks without usage data" do
      pid = UsageAccumulator.new()

      UsageAccumulator.scan_chunk(
        pid,
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\n"
      )

      assert {nil, nil} = UsageAccumulator.get_tokens(pid)
    end

    test "returns {nil, nil} when no usage found" do
      pid = UsageAccumulator.new()
      assert {nil, nil} = UsageAccumulator.get_tokens(pid)
    end

    test "handles multi-event chunks" do
      pid = UsageAccumulator.new()

      chunk =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\ndata: {\"usage\":{\"input_tokens\":5,\"output_tokens\":10}}\n\n"

      UsageAccumulator.scan_chunk(pid, chunk)
      assert {5, 10} = UsageAccumulator.get_tokens(pid)
    end

    test "handles non-JSON data lines gracefully" do
      pid = UsageAccumulator.new()
      UsageAccumulator.scan_chunk(pid, "data: [DONE]\n\n")
      assert {nil, nil} = UsageAccumulator.get_tokens(pid)
    end

    test "handles chunks without data: prefix" do
      pid = UsageAccumulator.new()
      UsageAccumulator.scan_chunk(pid, ": heartbeat\n\n")
      assert {nil, nil} = UsageAccumulator.get_tokens(pid)
    end
  end

  describe "Responses observer projection" do
    test "alias mapper large native frames retain cached and final token usage" do
      for size <- [270_000, 600_000] do
        pid = UsageAccumulator.new(:openai_responses)
        on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)
        mapper = Backplane.LLM.ModelResponse.responses_stream_mapper("expert", "gpt-6-sol")

        first =
          "data: " <>
            Jason.encode!(%{
              "type" => "response.created",
              "response" => %{"padding" => String.duplicate("x", size)}
            }) <> "\n\n"

        terminal =
          ~S(data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":3,"input_tokens_details":{"cached_tokens":2}}}}) <>
            "\n\n"

        Enum.each(mapper.(first), &UsageAccumulator.scan_chunk(pid, &1))

        # Model output follows the initial event; parser behavior is separate from snapshot deadlines.
        Agent.get(pid, & &1)
        Enum.each(mapper.(terminal), &UsageAccumulator.scan_chunk(pid, &1))

        assert %{input_tokens: 5, output_tokens: 3, cached_tokens: 2, usage_complete: true} =
                 UsageAccumulator.snapshot(pid, 200)
      end
    end

    test "observes fragmented non-streaming JSON bodies" do
      pid = UsageAccumulator.new(:openai_responses_body)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      body =
        ~S({"id":"resp_body","status":"completed","output":[],"usage":{"input_tokens":8,"output_tokens":5}})

      {first, second} = String.split_at(body, 41)
      UsageAccumulator.scan_chunk(pid, first)
      UsageAccumulator.scan_chunk(pid, second)

      snapshot = UsageAccumulator.snapshot(pid, 200)
      assert snapshot.input_tokens == 8
      assert snapshot.output_tokens == 5
      assert snapshot.provider_request_id == "resp_body"
      assert snapshot.protocol_terminal == :completed
      assert snapshot.metadata.protocol_observation.implementation =~ "OpenAIResponsesObserver"
    end

    test "bounds non-streaming JSON accumulation" do
      pid = UsageAccumulator.new(:openai_responses_body, snapshot_timeout: 500)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      chunk = String.duplicate("x", 1_048_576)
      Enum.each(1..9, fn _ -> UsageAccumulator.scan_chunk(pid, chunk) end)

      snapshot = UsageAccumulator.snapshot(pid, 200)
      assert snapshot.input_tokens == nil
      assert snapshot.output_tokens == nil
      assert snapshot.partial == true
      assert snapshot.metadata.protocol_observation.input_truncated == true

      assert "response_bytes_exceeded" in snapshot.metadata.protocol_observation.diagnostics
    end

    test "drops an oversized observation chunk without retaining it" do
      pid = UsageAccumulator.new(:openai_responses_body)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      UsageAccumulator.scan_chunk(pid, String.duplicate("x", 1_048_577))

      snapshot = UsageAccumulator.snapshot(pid, 200)
      assert snapshot.partial == true
      assert snapshot.metadata.observation.dropped_chunks == 1
      assert snapshot.metadata.observation.queue_saturated == false
      assert snapshot.metadata.observation.oversized_chunks == 1
    end

    test "observes native Chat Completions JSON on the bounded worker" do
      pid = UsageAccumulator.new(:openai_json_body)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      UsageAccumulator.scan_chunk(
        pid,
        ~S({"id":"chat_1","choices":[{"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":3}})
      )

      snapshot = UsageAccumulator.snapshot(pid, 200)
      assert snapshot.input_tokens == 7
      assert snapshot.output_tokens == 3
      assert snapshot.finish_reason == "stop"
      assert snapshot.provider_request_id == "chat_1"
      assert snapshot.observation_status == :complete
    end

    test "normalizes tool call keys while retaining nested JSON string keys" do
      pid = UsageAccumulator.new(:openai_responses)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      UsageAccumulator.scan_chunk(
        pid,
        ~S(data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","name":"lookup","arguments":"{\"query\":{\"term\":\"elixir\"}}","status":"completed"}}) <>
          "\n\n"
      )

      UsageAccumulator.scan_chunk(
        pid,
        ~S(data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}) <>
          "\n\n"
      )

      snapshot = UsageAccumulator.snapshot(pid)

      assert [%{name: "lookup", arguments: %{"query" => %{"term" => "elixir"}}}] =
               snapshot.tool_calls

      assert snapshot.protocol == :responses
      assert snapshot.partial == false
      assert snapshot.usage_complete == true
    end

    test "propagates malformed arguments and interrupted usage as partial" do
      pid = UsageAccumulator.new(:openai_responses)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      UsageAccumulator.scan_chunk(
        pid,
        ~S(data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","name":"lookup","arguments":"{" ,"status":"completed"}}) <>
          "\n\n"
      )

      UsageAccumulator.scan_chunk(
        pid,
        ~S(data: {"type":"response.in_progress","response":{"usage":{"input_tokens":2}}}) <>
          "\n\n"
      )

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.input_tokens == 2
      assert snapshot.output_tokens == nil
      assert snapshot.partial == true
      assert snapshot.usage_complete == false
      assert [%{complete: false}] = snapshot.tool_calls
      assert snapshot.metadata.protocol_observation.diagnostics != []
      assert Process.alive?(pid)
    end

    test "keeps compact on its dedicated legacy parser identity" do
      pid = UsageAccumulator.new(:compact)
      on_exit(fn -> if Process.alive?(pid), do: UsageAccumulator.stop(pid) end)

      UsageAccumulator.scan_chunk(
        pid,
        ~S(data: {"usage":{"prompt_tokens":4,"completion_tokens":2}}) <> "\n\n"
      )

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.protocol == :compact
      assert snapshot.input_tokens == 4
      assert snapshot.output_tokens == 2
      assert snapshot.metadata == %{}
    end
  end

  describe "observation isolation" do
    test "observes wrapped Antigravity JSON and SSE" do
      body =
        Jason.encode!(%{
          "response" => %{
            "candidates" => [%{"finishReason" => "STOP"}],
            "usageMetadata" => %{"promptTokenCount" => 7, "candidatesTokenCount" => 4}
          },
          "native" => %{"keep" => true}
        })

      for {protocol, chunk} <- [
            {:google_antigravity_body, body},
            {:google_antigravity, "data: " <> body <> "\n\n"}
          ] do
        pid = UsageAccumulator.new(protocol)
        UsageAccumulator.scan_chunk(pid, chunk)

        assert %{
                 input_tokens: 7,
                 output_tokens: 4,
                 metadata: %{protocol_observation: %{source: :google_antigravity}}
               } = UsageAccumulator.snapshot(pid, 200)

        UsageAccumulator.stop(pid)
      end
    end

    test "observer metadata does not depend on the process that created it" do
      parent = self()

      creator =
        spawn(fn ->
          pid = UsageAccumulator.new()
          send(parent, {:accumulator, pid})
        end)

      ref = Process.monitor(creator)
      assert_receive {:accumulator, pid}
      assert_receive {:DOWN, ^ref, :process, ^creator, :normal}
      on_exit(fn -> UsageAccumulator.stop(pid) end)

      assert :ok =
               UsageAccumulator.scan_chunk(
                 pid,
                 "data: {\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n"
               )

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.input_tokens == 3
      assert snapshot.output_tokens == 2
    end

    test "scan_chunk remains successful and snapshot is unavailable after its owner exits" do
      pid = UsageAccumulator.new()
      Process.exit(pid, :kill)
      refute Process.alive?(pid)

      assert :ok = UsageAccumulator.scan_chunk(pid, "data: {\"usage\":{\"prompt_tokens\":1}}\n\n")

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.observation_status == :unavailable
      assert snapshot.partial == true
      assert snapshot.usage_complete == false
    end

    test "queue saturation is nonblocking and marked incomplete" do
      pid = UsageAccumulator.new(:legacy, max_queue: 0)
      on_exit(fn -> UsageAccumulator.stop(pid) end)

      assert :ok = UsageAccumulator.scan_chunk(pid, "data: {\"usage\":{\"prompt_tokens\":1}}\n\n")

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.observation_status == :incomplete
      assert snapshot.partial == true
      assert snapshot.usage_complete == false
      assert snapshot.metadata.observation.dropped_chunks == 1
      assert snapshot.metadata.observation.queue_saturated == true
    end

    test "snapshot returns unavailable instead of waiting on a stalled observer" do
      pid = UsageAccumulator.new(:legacy, snapshot_timeout: 5)
      on_exit(fn -> UsageAccumulator.stop(pid) end)
      :erlang.suspend_process(pid)

      started = System.monotonic_time(:millisecond)
      snapshot = UsageAccumulator.snapshot(pid)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 100
      assert snapshot.observation_status == :unavailable
      assert snapshot.partial == true
      :erlang.resume_process(pid)
    end
  end
end
