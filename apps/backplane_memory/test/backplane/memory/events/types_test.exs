defmodule Backplane.Memory.Events.TypesTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Types

  @accepted_types ~w(
    session.started
    session.ended
    conversation.user_message
    conversation.agent_message
    agent.run.started
    agent.run.completed
    agent.run.failed
    tool.call.started
    tool.call.completed
    tool.call.failed
    task.created
    task.updated
    task.completed
    memory.recalled
    heartbeat.triggered
    dream.started
    dream.completed
    schedule.triggered
    legacy.observation
  )

  test "accepts every exact taxonomy value and rejects close variants" do
    assert Types.accepted_types() == @accepted_types

    for event_type <- @accepted_types do
      assert {:ok, %{event_type: ^event_type}} =
               Types.normalize(%{stream_id: "stream", event_type: event_type})
    end

    for event_type <- [
          "session.start",
          "session.started ",
          "agent.run.complete",
          "tool.call.failure",
          "legacy.observations"
        ] do
      assert {:error, :invalid_event_type} =
               Types.normalize(%{stream_id: "stream", event_type: event_type})
    end
  end

  test "derives a session stream and supplies defaults" do
    assert {:ok, attrs} =
             Types.normalize(%{"event_type" => "session.started", "session_id" => "s1"})

    assert attrs.stream_id == "session:s1"
    assert attrs.namespace == "private"
    assert attrs.payload == %{}
    assert attrs.importance == 0
    assert %DateTime{} = attrs.occurred_at
    assert {:ok, _} = Ecto.UUID.cast(attrs.id)
  end

  test "an explicit stream wins and an invalid explicit stream never falls back to the session" do
    assert {:ok, %{stream_id: "explicit"}} =
             Types.normalize(%{
               stream_id: "explicit",
               session_id: "session",
               event_type: "session.started"
             })

    for invalid_stream <- [nil, "", 42] do
      assert {:error, :missing_identity} =
               Types.normalize(%{
                 stream_id: invalid_stream,
                 session_id: "session",
                 event_type: "session.started"
               })
    end

    for invalid_session <- [nil, "", 42] do
      assert {:error, :missing_identity} =
               Types.normalize(%{
                 session_id: invalid_session,
                 event_type: "session.started"
               })
    end

    assert {:error, :missing_identity} =
             Types.normalize(%{project: "backplane", event_type: "session.started"})
  end

  test "normalizes only fixed string aliases without creating atoms" do
    unknown_key = "unknown_#{System.unique_integer([:positive, :monotonic])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert {:ok, attrs} =
             Types.normalize(%{
               "type" => "task.created",
               "stream" => "stream",
               unknown_key => "ignored"
             })

    assert attrs.event_type == "task.created"
    assert attrs.stream_id == "stream"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert {:ok, _attrs} =
             Types.normalize(%{event_type: "task.created", stream_id: "stream"})

    assert {:ok, %{event_type: "task.created"}} =
             Types.normalize(%{"TYPE" => "task.created", "stream_id" => "stream"})

    assert {:error, :invalid_event_type} =
             Types.normalize(%{type: "task.created", stream_id: "stream"})
  end

  test "rejects missing identity, invalid type, payload, importance, and conflicting aliases" do
    assert {:error, :missing_identity} = Types.normalize(%{"event_type" => "session.started"})
    assert {:error, :invalid_event_type} = Types.normalize(%{stream_id: "s", event_type: "nope"})

    assert {:error, :invalid_payload} =
             Types.normalize(%{stream_id: "s", event_type: "legacy.observation", payload: []})

    assert {:error, :invalid_importance} =
             Types.normalize(%{stream_id: "s", event_type: "legacy.observation", importance: 1.0})

    conflict =
      Map.new([{:stream_id, "s1"}, {"stream_id", "s2"}, {:event_type, "legacy.observation"}])

    assert {:error, :conflicting_keys} = Types.normalize(conflict)
    assert {:error, {:invalid_key, 42}} = Types.normalize(%{42 => "bad"})
  end

  test "accepts recursively JSON-safe payloads and rejects unsafe nested values" do
    payload = %{
      "items" => [1, true, nil, %{"nested" => ["value"]}],
      "metadata" => %{"ratio" => 1.5}
    }

    assert {:ok, %{payload: ^payload}} =
             Types.normalize(%{
               stream_id: "stream",
               event_type: "task.updated",
               payload: payload
             })

    for invalid_payload <- [
          %{"nested" => [%{atom_key: "value"}]},
          %{"tuple" => {:not, "json"}},
          %{"struct" => DateTime.utc_now()}
        ] do
      assert {:error, :invalid_payload} =
               Types.normalize(%{
                 stream_id: "stream",
                 event_type: "task.updated",
                 payload: invalid_payload
               })
    end
  end

  test "rejects improper lists at every payload depth without raising" do
    for invalid_payload <- [
          %{"improper" => [1 | 2]},
          %{"improper" => [1 | nil]},
          %{"nested" => [[%{"valid" => true} | "tail"]]}
        ] do
      assert {:error, :invalid_payload} =
               Types.normalize(%{
                 stream_id: "stream",
                 event_type: "task.updated",
                 payload: invalid_payload
               })
    end
  end

  test "accepts only signed 32-bit importance values" do
    for importance <- [-2_147_483_648, 2_147_483_647] do
      assert {:ok, %{importance: ^importance}} =
               Types.normalize(%{
                 stream_id: "stream",
                 event_type: "task.updated",
                 importance: importance
               })
    end

    for importance <- [-2_147_483_649, 2_147_483_648] do
      assert {:error, :invalid_importance} =
               Types.normalize(%{
                 stream_id: "stream",
                 event_type: "task.updated",
                 importance: importance
               })
    end
  end

  test "canonicalizes ISO timestamps and UUIDs" do
    id = Ecto.UUID.generate()
    payload = %{"kind" => "supplied"}

    assert {:ok, attrs} =
             Types.normalize(%{
               stream_id: "s",
               event_type: "legacy.observation",
               id: String.upcase(id),
               namespace: "project",
               payload: payload,
               importance: 7,
               occurred_at: "2026-01-01T00:00:00+02:00"
             })

    assert attrs.id == id
    assert attrs.namespace == "project"
    assert attrs.payload == payload
    assert attrs.importance == 7
    assert DateTime.compare(attrs.occurred_at, ~U[2025-12-31 22:00:00Z]) == :eq

    assert {:error, :invalid_uuid} =
             Types.normalize(%{stream_id: "s", event_type: "legacy.observation", id: "bad"})
  end

  test "canonicalizes and validates an optional causation UUID" do
    causation_id = Ecto.UUID.generate()

    assert {:ok, attrs} =
             Types.normalize(%{
               stream_id: "s",
               event_type: "task.updated",
               causation_id: String.upcase(causation_id)
             })

    assert attrs.causation_id == causation_id

    assert {:ok, %{causation_id: nil}} =
             Types.normalize(%{
               stream_id: "s",
               event_type: "task.updated",
               causation_id: nil
             })

    assert {:ok, without_causation} =
             Types.normalize(%{stream_id: "s", event_type: "task.updated"})

    refute Map.has_key?(without_causation, :causation_id)

    assert {:error, :invalid_uuid} =
             Types.normalize(%{
               stream_id: "s",
               event_type: "task.updated",
               causation_id: "not-a-uuid"
             })
  end
end
