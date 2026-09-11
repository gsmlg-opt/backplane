defmodule Backplane.AgentRuntime.EventTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Event
  alias Backplane.AgentRuntime.EventStream

  describe "event envelopes" do
    test "builds stable serializable envelopes" do
      assert {:ok, event} =
               Event.build(%{
                 event_id: "event_1",
                 aggregate_id: "run_1",
                 sequence: 1,
                 type: "run.started",
                 occurred_at: 10,
                 causation_id: "caused_1",
                 payload: %{"state" => "running"}
               })

      assert event.schema_version == 1
      assert event.payload == %{"state" => "running"}
    end

    test "rejects missing identities, invalid time, and invalid sequences" do
      base = %{
        event_id: "event_1",
        aggregate_id: "run_1",
        sequence: 1,
        type: "run.started",
        occurred_at: 10
      }

      assert {:error, %Error{}} = Event.build(Map.delete(base, :event_id))
      assert {:error, %Error{}} = Event.build(%{base | occurred_at: -1})
      assert {:error, %Error{}} = Event.build(%{base | sequence: -1})
    end
  end

  describe "bounded replay" do
    test "appends sequential events and replays by cursor" do
      {:ok, stream} = EventStream.new(2)

      assert {:ok, stream} =
               EventStream.append(stream, %{
                 event_id: "event_1",
                 aggregate_id: "run_1",
                 sequence: 0,
                 type: "run.started",
                 occurred_at: 10
               })

      assert {:ok, stream} =
               EventStream.append(stream, %{
                 event_id: "event_2",
                 aggregate_id: "run_1",
                 sequence: 1,
                 type: "run.running",
                 occurred_at: 11
               })

      assert {:ok, [%{event_id: "event_2"}], _cursor} = EventStream.replay(stream, 1)

      assert {:ok, _events, _cursor} = EventStream.replay(stream, 0)
    end

    test "rejects duplicate aggregate sequences and gaps" do
      {:ok, stream} = EventStream.new(10)

      {:ok, stream} =
        EventStream.append(stream, %{
          event_id: "event_1",
          aggregate_id: "run_1",
          sequence: 0,
          type: "run.started",
          occurred_at: 10
        })

      assert {:error, %Error{}} =
               EventStream.append(stream, %{
                 event_id: "event_2",
                 aggregate_id: "run_1",
                 sequence: 0,
                 type: "run.running",
                 occurred_at: 11
               })

      assert {:error, %Error{}} =
               EventStream.append(stream, %{
                 event_id: "event_2",
                 aggregate_id: "run_1",
                 sequence: 5,
                 type: "run.running",
                 occurred_at: 12
               })
    end
  end
end
