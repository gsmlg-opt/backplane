defmodule Backplane.Memory.Events.TypesTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Types

  test "accepts the exact taxonomy and derives a session stream" do
    assert length(Types.accepted_types()) == 19

    assert {:ok, attrs} =
             Types.normalize(%{"event_type" => "session.started", "session_id" => "s1"})

    assert attrs.stream_id == "session:s1"
    assert attrs.namespace == "private"
    assert attrs.payload == %{}
    assert attrs.importance == 0
    assert %DateTime{} = attrs.occurred_at
    assert {:ok, _} = Ecto.UUID.cast(attrs.id)
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

  test "canonicalizes ISO timestamps and UUIDs" do
    id = Ecto.UUID.generate()

    assert {:ok, attrs} =
             Types.normalize(%{
               stream_id: "s",
               event_type: "legacy.observation",
               id: id,
               occurred_at: "2026-01-01T00:00:00+02:00"
             })

    assert {:ok, ^id} = Ecto.UUID.cast(attrs.id)
    assert DateTime.compare(attrs.occurred_at, ~U[2025-12-31 22:00:00Z]) == :eq

    assert {:error, :invalid_uuid} =
             Types.normalize(%{stream_id: "s", event_type: "legacy.observation", id: "bad"})
  end
end
