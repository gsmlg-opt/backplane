defmodule Backplane.Memory.Distill.ChunkerTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Distill.Chunker
  alias Backplane.Memory.Projections.ProjectedObservation

  defp obs(seq, attrs \\ %{}) do
    struct(
      ProjectedObservation,
      Map.merge(
        %{
          event_id: Ecto.UUID.generate(),
          source_sequence: seq,
          event_type: "tool_use",
          occurred_at: DateTime.add(~U[2026-11-01 00:00:00.000000Z], seq, :second),
          tool_name: "Bash",
          content: "content #{seq}"
        },
        attrs
      )
    )
  end

  test "renders observations ordered by source_sequence" do
    [a, b, c] = [obs(3), obs(1), obs(2, %{content: nil, message: "from message"})]

    assert [[first, second, third]] = Chunker.chunks([a, b, c], 24_000)

    assert first == %{
             "event_id" => b.event_id,
             "at" => "2026-11-01T00:00:01.000000Z",
             "type" => "tool_use",
             "tool" => "Bash",
             "content" => "content 1"
           }

    assert second["content"] == "from message"
    assert third["event_id"] == a.event_id
  end

  test "greedy-packs by encoded size and never emits empty chunks" do
    observations = for seq <- 1..10, do: obs(seq, %{content: String.duplicate("x", 300)})
    one = byte_size(Jason.encode!(hd(Chunker.chunks([hd(observations)], 24_000))))

    chunks = Chunker.chunks(observations, one * 3 + 10)

    assert Enum.map(chunks, &length/1) == [3, 3, 3, 1]
    assert Enum.all?(chunks, &(byte_size(Jason.encode!(&1)) <= one * 3 + 10))
    assert chunks |> List.flatten() |> Enum.map(& &1["content"]) |> length() == 10
    assert Chunker.chunks([], 24_000) == []
  end

  test "truncates oversized content to 4000 bytes and keeps it in its own chunk" do
    big = obs(1, %{content: String.duplicate("é", 5_000)})
    small = obs(2)

    assert [[rendered], [_small]] = Chunker.chunks([big, small], 3_000)
    assert byte_size(rendered["content"]) <= 4_000
    assert byte_size(rendered["content"]) >= 3_998
    assert String.valid?(rendered["content"])
  end

  test "defaults max_bytes to 24_000" do
    observations = for seq <- 1..10, do: obs(seq, %{content: String.duplicate("y", 3_900)})
    chunks = Chunker.chunks(observations)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(byte_size(Jason.encode!(&1)) <= 24_000))
  end

  test "renders tool input, error flag and file paths when present" do
    o =
      obs(1, %{
        event_type: "agent.tool.completed",
        content: "ok",
        is_error: true,
        file_paths: ["/srv/app/config.exs"]
      })

    plain = obs(2, %{is_error: false, file_paths: []})

    assert [[rendered, rendered_plain]] =
             Chunker.chunks([{o, %{"command" => "mix test", "timeout" => 5}}, {plain, nil}])

    assert rendered["input"] == ~s({"command":"mix test","timeout":5})
    assert rendered["error"] == true
    assert rendered["files"] == ["/srv/app/config.exs"]

    refute Map.has_key?(rendered_plain, "input")
    refute Map.has_key?(rendered_plain, "error")
    refute Map.has_key?(rendered_plain, "files")
  end

  test "truncates tool input to 1500 bytes, UTF-8 safe" do
    o = obs(1)
    assert [[rendered]] = Chunker.chunks([{o, %{"command" => String.duplicate("é", 2_000)}}])

    assert byte_size(rendered["input"]) <= 1_500
    assert byte_size(rendered["input"]) >= 1_498
    assert String.valid?(rendered["input"])
  end

  test "drops observations whose content is only the event type and that have no input" do
    bare = obs(1, %{event_type: "agent.tool.completed", content: "agent.tool.completed"})
    with_input = obs(2, %{event_type: "agent.tool.completed", content: "agent.tool.completed"})
    kept = obs(3)

    assert [[a, b]] = Chunker.chunks([{bare, nil}, {with_input, %{"command" => "ls"}}, kept])
    assert a["event_id"] == with_input.event_id
    assert b["event_id"] == kept.event_id
    assert Chunker.chunks([{bare, nil}]) == []
  end
end
