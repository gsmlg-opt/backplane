defmodule Backplane.LLM.UsageAccumulatorTimingTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.UsageAccumulator

  test "TTFT uses request origin and effective content, excluding heartbeat, role and usage" do
    origin = System.monotonic_time(:millisecond) - 200
    pid = accumulator(:legacy, started_at_mono: origin)

    UsageAccumulator.scan_chunk(pid, ": heartbeat\n\n")
    feed(pid, %{"choices" => [%{"delta" => %{"role" => "assistant", "content" => ""}}]})
    feed(pid, %{"usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2}})
    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.ttft_ms == nil
    assert snapshot.stream_duration_ms == nil
    refute Map.has_key?(snapshot.metadata, :timing)

    first = System.monotonic_time(:millisecond)
    feed(pid, %{"choices" => [%{"delta" => %{"content" => "hello"}}]})
    last = System.monotonic_time(:millisecond)
    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.ttft_ms in (first - origin)..(last - origin)
    assert snapshot.metadata.timing.basis == "first_content"
    assert snapshot.input_tokens == 4
    assert snapshot.output_tokens == 2
  end

  test "arrival and completion clocks exclude time waiting on the observer worker" do
    origin = System.monotonic_time(:millisecond) - 100
    pid = accumulator(:legacy, started_at_mono: origin, snapshot_timeout: 1_000)
    :erlang.suspend_process(pid)
    first = System.monotonic_time(:millisecond)
    feed(pid, %{"choices" => [%{"delta" => %{"content" => "hello"}}]})
    last = System.monotonic_time(:millisecond)
    Process.sleep(80)

    parent = self()
    spawn(fn -> send(parent, {:snapshot, UsageAccumulator.snapshot(pid)}) end)
    Process.sleep(80)
    :erlang.resume_process(pid)
    assert_receive {:snapshot, snapshot}, 1_000
    assert snapshot.ttft_ms in (first - origin)..(last - origin)
    assert snapshot.stream_duration_ms >= 70
    assert snapshot.stream_duration_ms < 140
  end

  test "fragmented SSE retains usage and detects the content event when its frame arrives" do
    origin = System.monotonic_time(:millisecond) - 100
    pid = accumulator(:compact, started_at_mono: origin)
    UsageAccumulator.scan_chunk(pid, "data: {\"choices\":[{\"delta\":{\"content\":\"hel")
    first = System.monotonic_time(:millisecond)
    UsageAccumulator.scan_chunk(pid, "lo\"}}]}\r\n\r\ndata:{\"usage\":{\"prompt_tokens\":2,")
    last = System.monotonic_time(:millisecond)
    UsageAccumulator.scan_chunk(pid, "\"completion_tokens\":3}}\n\n")
    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.ttft_ms in (first - origin)..(last - origin)
    assert snapshot.input_tokens == 2
    assert snapshot.output_tokens == 3
    assert snapshot.protocol == :compact
  end

  for {name, protocol, content} <- [
        {"chat reasoning", :legacy,
         %{"choices" => [%{"delta" => %{"reasoning_content" => "think"}}]}},
        {"chat tool arguments", :legacy,
         %{
           "choices" => [
             %{"delta" => %{"tool_calls" => [%{"function" => %{"arguments" => "{"}}]}}
           ]
         }},
        {"anthropic text", :legacy,
         %{"type" => "content_block_delta", "delta" => %{"text" => "hi"}}},
        {"anthropic reasoning", :legacy,
         %{"type" => "content_block_delta", "delta" => %{"thinking" => "think"}}},
        {"anthropic arguments", :legacy,
         %{"type" => "content_block_delta", "delta" => %{"partial_json" => "{"}}},
        {"anthropic initial text", :legacy,
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "text", "text" => "hi"}
         }},
        {"anthropic initial reasoning", :legacy,
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "thinking", "thinking" => "think"}
         }},
        {"anthropic initial arguments", :legacy,
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "tool_use", "name" => "lookup", "input" => %{"a" => 1}}
         }},
        {"responses text", :responses,
         %{"type" => "response.output_text.delta", "delta" => "hi"}},
        {"responses reasoning", :responses,
         %{"type" => "response.reasoning_summary_text.delta", "delta" => "think"}},
        {"responses tool arguments", :responses,
         %{"type" => "response.function_call_arguments.delta", "delta" => "{"}},
        {"google text", :google_generate_content,
         %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}},
        {"google thought", :google_generate_content,
         %{
           "candidates" => [
             %{"content" => %{"parts" => [%{"thought" => true, "text" => "think"}]}}
           ]
         }},
        {"google arguments", :google_generate_content,
         %{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [%{"functionCall" => %{"name" => "tool", "args" => %{"a" => 1}}}]
               }
             }
           ]
         }},
        {"antigravity", :google_antigravity,
         %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}}}
      ] do
    test "#{name} starts measured timing" do
      pid =
        accumulator(unquote(protocol), started_at_mono: System.monotonic_time(:millisecond) - 100)

      feed(pid, unquote(Macro.escape(content)))
      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.ttft_ms >= 100
      assert is_integer(snapshot.stream_duration_ms)
      assert snapshot.metadata.timing.basis == "first_content"
    end
  end

  test "Google empty parts and tool names do not count as content" do
    for protocol <- [:google_generate_content, :google_antigravity] do
      pid = accumulator(protocol)

      doc = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{}, %{"text" => ""}, %{"functionCall" => %{"name" => "lookup"}}]
            }
          }
        ]
      }

      feed(pid, if(protocol == :google_antigravity, do: %{"response" => doc}, else: doc))
      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.ttft_ms == nil
      assert snapshot.stream_duration_ms == nil
      assert snapshot.metadata.timing.first_content_ms == nil
      refute Map.has_key?(snapshot.metadata.timing, :basis)
    end
  end

  test "Anthropic empty initial content and tool names do not count as content" do
    pid = accumulator(:legacy)

    feed(pid, %{
      "type" => "content_block_start",
      "content_block" => %{"type" => "text", "text" => ""}
    })

    feed(pid, %{
      "type" => "content_block_start",
      "content_block" => %{"type" => "tool_use", "name" => "lookup", "input" => %{}}
    })

    assert UsageAccumulator.snapshot(pid).ttft_ms == nil
  end

  test "Responses lifecycle and terminal output never substitute for delta timing" do
    pid = accumulator(:responses)
    feed(pid, %{"type" => "response.output_text.delta", "delta" => ""})
    feed(pid, %{"type" => "response.created", "response" => %{"status" => "in_progress"}})

    feed(pid, %{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "output" => [%{"content" => [%{"type" => "output_text", "text" => "already complete"}]}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      }
    })

    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.ttft_ms == nil
    assert snapshot.stream_duration_ms == nil
    refute Map.has_key?(snapshot.metadata, :timing)
    assert snapshot.output_tokens == 2
  end

  test "finishing an unterminated frame does not invent stream content timing" do
    pid = accumulator(:google_generate_content)

    UsageAccumulator.scan_chunk(
      pid,
      ~s(data: {"candidates":[{"content":{"parts":[{"text":"late"}]}}]})
    )

    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.ttft_ms == nil
    assert snapshot.metadata.timing.first_content_ms == nil
  end

  test "dropped chunks and framing bounds invalidate timing" do
    for protocol <- [:legacy, :responses, :google_generate_content] do
      pid = accumulator(protocol)
      UsageAccumulator.scan_chunk(pid, String.duplicate("x", 1_048_577))
      feed(pid, content(protocol))
      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.ttft_ms == nil
      assert snapshot.stream_duration_ms == nil
      refute get_in(snapshot.metadata, [:timing, :basis])

      bounded = accumulator(protocol)
      UsageAccumulator.scan_chunk(bounded, "data: " <> String.duplicate("x", 600_000))
      UsageAccumulator.scan_chunk(bounded, String.duplicate("x", 600_000) <> "\n\n")
      feed(bounded, content(protocol))
      snapshot = UsageAccumulator.snapshot(bounded)
      assert snapshot.ttft_ms == nil
      assert snapshot.stream_duration_ms == nil
    end
  end

  test "legacy terminal usage remains observable after timing budgets are exhausted" do
    for protocol <- [:legacy, :compact] do
      pid = accumulator(protocol)

      UsageAccumulator.scan_chunk(
        pid,
        String.duplicate(~s(data: {"type":"ping"}) <> "\n\n", 10_001)
      )

      feed(pid, %{"usage" => %{"prompt_tokens" => 8, "completion_tokens" => 5}})
      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.input_tokens == 8
      assert snapshot.output_tokens == 5
      assert snapshot.ttft_ms == nil
      assert snapshot.stream_duration_ms == nil
    end
  end

  test "legacy terminal usage remains observable after the timing framer rejects a frame" do
    pid = accumulator(:legacy)
    UsageAccumulator.scan_chunk(pid, "data: " <> String.duplicate("x", 600_000))
    UsageAccumulator.scan_chunk(pid, String.duplicate("x", 600_000) <> "\n\n")
    feed(pid, %{"usage" => %{"prompt_tokens" => 8, "completion_tokens" => 5}})
    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.input_tokens == 8
    assert snapshot.output_tokens == 5
    assert snapshot.ttft_ms == nil
  end

  test "legacy snapshots observe the latest terminal usage without a frame delimiter" do
    for protocol <- [:legacy, :compact] do
      pid = accumulator(protocol)

      UsageAccumulator.scan_chunk(
        pid,
        "data: {\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":1}}\n\ndata: {\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":5}}\n"
      )

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.input_tokens == 8
      assert snapshot.output_tokens == 5
    end
  end

  test "fragmented unterminated terminal usage is observed on a copy without closing the live framer" do
    pid = accumulator(:legacy)
    UsageAccumulator.scan_chunk(pid, "data: {\"usage\":{\"prompt_tokens\":8,")
    UsageAccumulator.scan_chunk(pid, "\"completion_tokens\":5}}\n")
    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.input_tokens == 8
    assert snapshot.output_tokens == 5

    UsageAccumulator.scan_chunk(
      pid,
      "\ndata: {\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":7}}\n\n"
    )

    snapshot = UsageAccumulator.snapshot(pid)
    assert snapshot.input_tokens == 8
    assert snapshot.output_tokens == 7
  end

  test "non-streaming body modes never expose TTFT or generation duration" do
    for protocol <- [
          :openai_responses_body,
          :openai_json_body,
          :anthropic_json_body,
          :google_generate_content_body,
          :google_antigravity_body,
          :google_count_tokens_body
        ] do
      pid = accumulator(protocol)

      UsageAccumulator.scan_chunk(
        pid,
        ~s({"status":"completed","candidates":[{"content":{"parts":[{"text":"body"}]},"finishReason":"STOP"}],"usage":{"input_tokens":1,"output_tokens":2},"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":2}})
      )

      snapshot = UsageAccumulator.snapshot(pid)
      assert snapshot.ttft_ms == nil
      assert snapshot.stream_duration_ms == nil
      refute get_in(snapshot.metadata, [:timing, :basis])
    end
  end

  defp accumulator(protocol, opts \\ []) do
    pid = UsageAccumulator.new(protocol, Keyword.put_new(opts, :snapshot_timeout, 1_000))
    on_exit(fn -> UsageAccumulator.stop(pid) end)
    pid
  end

  defp feed(pid, document),
    do: UsageAccumulator.scan_chunk(pid, "data: " <> Jason.encode!(document) <> "\n\n")

  defp content(:responses), do: %{"type" => "response.output_text.delta", "delta" => "hi"}

  defp content(:google_generate_content),
    do: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}

  defp content(:legacy), do: %{"choices" => [%{"delta" => %{"content" => "hi"}}]}
end
