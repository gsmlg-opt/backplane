defmodule Backplane.Memory.EventsTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events

  test "append normalizes, sanitizes, and returns an Event struct" do
    assert {:ok, event} =
             Events.append(%{
               "event_type" => "legacy.observation",
               "session_id" => "s1",
               "content" => "hello"
             })

    assert %Backplane.Memory.Events.Event{} = event
    assert event.stream_id == "session:s1"
    assert event.content == "hello"
  end

  test "append rejects invalid attributes before persistence" do
    assert {:error, :missing_identity} = Events.append(%{event_type: "legacy.observation"})

    assert {:error, :invalid_payload} =
             Events.append(%{stream_id: "s", event_type: "legacy.observation", payload: []})

    assert {:error, :missing_identity} =
             Events.append(%{
               stream_id: nil,
               session_id: "session",
               event_type: "legacy.observation"
             })

    assert {:error, :invalid_uuid} =
             Events.append(%{stream_id: "s", event_type: "legacy.observation", id: "bad"})

    assert {:error, :invalid_uuid} =
             Events.append(%{
               stream_id: "s",
               event_type: "legacy.observation",
               causation_id: "bad"
             })
  end

  test "append_batch preserves order and stops at the first invalid item" do
    assert {:ok, [first, second]} =
             Events.append_batch([
               %{stream_id: "s", event_type: "task.created", content: "one"},
               %{stream_id: "s", event_type: "task.updated", content: "two"}
             ])

    assert [first.event_type, second.event_type] == ["task.created", "task.updated"]

    assert {:error, :missing_identity} =
             Events.append_batch([
               %{stream_id: "s", event_type: "task.created"},
               %{event_type: "task.updated"}
             ])
  end
end
