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
    test "physically retains only the configured event window and replays inclusively" do
      {:ok, stream} = EventStream.new(2)

      stream =
        Enum.reduce(0..3, stream, fn sequence, stream ->
          assert {:ok, stream} =
                   EventStream.append(stream, %{
                     event_id: "event_#{sequence}",
                     aggregate_id: "run_1",
                     sequence: sequence,
                     type: "run.progress",
                     occurred_at: 10 + sequence
                   })

          stream
        end)

      assert Enum.map(stream.events, & &1.sequence) == [2, 3]
      assert {:ok, [%{sequence: 2}, %{sequence: 3}], [floor: 2]} = EventStream.replay(stream, 2)
      assert {:ok, [%{sequence: 3}], [floor: 2]} = EventStream.replay(stream, 3)
      assert {:ok, [], [floor: 2]} = EventStream.replay(stream, 4)
      assert {:error, %Error{class: :not_found}} = EventStream.replay(stream, 1)
    end

    test "zero retention preserves sequence fencing without retaining events" do
      {:ok, stream} = EventStream.new(0)

      {:ok, stream} =
        EventStream.append(stream, %{
          event_id: "event_0",
          aggregate_id: "opaque-run",
          sequence: 0,
          type: "run.started",
          occurred_at: 10
        })

      assert stream.events == []
      assert stream.cursor_floor == 1
      assert {:ok, [], [floor: 1]} = EventStream.replay(stream, 1)
      assert {:error, %Error{class: :not_found}} = EventStream.replay(stream, 0)

      for sequence <- [0, 2] do
        assert {:error, %Error{class: :validation}} =
                 EventStream.append(stream, %{
                   event_id: "bad_#{sequence}",
                   aggregate_id: "opaque-run",
                   sequence: sequence,
                   type: "run.progress",
                   occurred_at: 11
                 })
      end

      assert {:ok, next_stream} =
               EventStream.append(stream, %{
                 event_id: "event_1",
                 aggregate_id: "opaque-run",
                 sequence: 1,
                 type: "run.running",
                 occurred_at: 11
               })

      assert next_stream.events == []
      assert next_stream.cursor_floor == 2
    end

    test "rejects events from another aggregate instead of imposing global ordering" do
      {:ok, stream} = EventStream.new(2)

      {:ok, stream} =
        EventStream.append(stream, %{
          event_id: "event_0",
          aggregate_id: "run_a",
          sequence: 0,
          type: "run.started",
          occurred_at: 10
        })

      assert {:error, %Error{class: :validation}} =
               EventStream.append(stream, %{
                 event_id: "event_other",
                 aggregate_id: "run_b",
                 sequence: 1,
                 type: "run.started",
                 occurred_at: 11
               })
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
