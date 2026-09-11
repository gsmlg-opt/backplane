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
end
