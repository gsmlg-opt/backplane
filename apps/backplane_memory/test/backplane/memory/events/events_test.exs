defmodule Backplane.Memory.EventsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events
  alias Backplane.Memory.Events.{Event, Stream}

  test "append persists and allocates stream-local sequences" do
    stream_id = unique("facade")

    assert {:ok, first} =
             Events.append(%{stream_id: stream_id, event_type: "task.created"})

    assert {:ok, second} =
             Events.append(%{stream_id: stream_id, event_type: "task.updated"})

    assert [first.sequence, second.sequence] == [1, 2]
    assert repo().get!(Event, first.id).stream_id == stream_id
    assert repo().get!(Stream, stream_id).next_sequence == 3
  end

  test "append_batch persists in input order and rolls back preparation failure" do
    stream_id = unique("batch")

    assert {:ok, events} =
             Events.append_batch([
               %{stream_id: stream_id, event_type: "task.created"},
               %{stream_id: stream_id, event_type: "task.updated"}
             ])

    assert Enum.map(events, & &1.sequence) == [1, 2]

    invalid_stream = unique("invalid")

    assert {:error, :missing_identity} =
             Events.append_batch([
               %{stream_id: invalid_stream, event_type: "task.created"},
               %{event_type: "task.updated"}
             ])

    refute repo().get(Stream, invalid_stream)
  end

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
