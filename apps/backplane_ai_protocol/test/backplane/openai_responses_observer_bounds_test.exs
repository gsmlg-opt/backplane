defmodule Backplane.AiProtocol.OpenAIResponsesObserverBoundsTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.OpenAIResponsesObserver, as: Observer

  test "large native events retain trailing usage within observer bounds" do
    for size <- [270_000, 600_000] do
      facts = observe([created(size), completed()])
      assert facts.input_tokens == 5
      assert facts.output_tokens == 3
      assert facts.cached_tokens == 2
      assert facts.usage_status == :complete
      assert facts.observation_status == :complete
    end
  end

  test "coalesced small frames beyond the buffer limit are drained incrementally" do
    delta =
      event(%{"type" => "response.output_text.delta", "delta" => String.duplicate("x", 1000)})

    wire = String.duplicate(delta, 2200) <> completed()
    assert byte_size(wire) > 2_097_152
    facts = observe([wire])
    assert facts.events_seen == 2201
    assert facts.input_tokens == 5
    assert facts.usage_status == :complete
  end

  test "every CRLF chunk split retains terminal usage" do
    wire = String.replace(completed(), "\n", "\r\n")

    for offset <- 0..byte_size(wire) do
      <<first::binary-size(^offset), second::binary>> = wire

      assert %{input_tokens: 5, output_tokens: 3, usage_status: :complete} =
               observe([first, second])
    end
  end

  test "strict configured frame bounds remain fatal and diagnose their cause" do
    facts = observe([created(1000), completed()], max_frame_bytes: 256)
    assert facts.usage_status == :unknown
    assert facts.observation_status == :incomplete
    assert "invalid_sse" in facts.diagnostics
    assert "sse_frame_bytes_exceeded" in facts.diagnostics
  end

  test "strict configured buffer bounds diagnose their cause" do
    facts = observe([String.duplicate("x", 1024)], max_buffer_bytes: 128)
    assert facts.observation_status == :incomplete
    assert "invalid_sse" in facts.diagnostics
    assert "sse_buffer_bytes_exceeded" in facts.diagnostics
  end

  test "events beyond one MiB are still bounded rather than silently accepted" do
    facts = observe([created(1_048_576), completed()])
    assert facts.input_tokens == nil
    assert facts.usage_status == :unknown
    assert "sse_frame_bytes_exceeded" in facts.diagnostics
  end

  defp observe(chunks, opts \\ []) do
    chunks
    |> Enum.reduce(Observer.new(opts), &Observer.feed(&2, &1))
    |> Observer.finish(:eof)
    |> Observer.facts()
  end

  defp created(size),
    do:
      event(%{
        "type" => "response.created",
        "response" => %{"padding" => String.duplicate("x", size)}
      })

  defp completed do
    event(%{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "usage" => %{
          "input_tokens" => 5,
          "output_tokens" => 3,
          "input_tokens_details" => %{"cached_tokens" => 2}
        }
      }
    })
  end

  defp event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end
