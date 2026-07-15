defmodule Backplane.Memory.Events.SchemaTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.{Event, Stream, Types}

  test "stream schema has the ordered stream contract" do
    assert Stream.__schema__(:primary_key) == [:stream_id]

    assert Stream.__schema__(:fields) == [
             :stream_id,
             :project,
             :agent_id,
             :host_id,
             :client_id,
             :session_id,
             :run_id,
             :next_sequence,
             :last_window_sequence,
             :last_event_at,
             :closed_at,
             :inserted_at,
             :updated_at
           ]
  end

  test "event schema has inserted_at only" do
    assert Event.__schema__(:primary_key) == [:id]
    refute :updated_at in Event.__schema__(:fields)
    assert Event.__schema__(:type, :payload) == :map
    assert Event.__schema__(:type, :causation_id) == :binary_id
  end

  test "event changesets enforce the shared event taxonomy" do
    attrs = %{
      id: Ecto.UUID.generate(),
      stream_id: "stream",
      sequence: 1,
      namespace: "private",
      event_type: "session.started",
      importance: 0,
      payload: %{},
      occurred_at: DateTime.utc_now()
    }

    assert Event.changeset(%Event{}, attrs).valid?

    changeset = Event.changeset(%Event{}, %{attrs | event_type: "session.start"})
    refute changeset.valid?

    assert {"is invalid", validation} = changeset.errors[:event_type]
    assert validation[:validation] == :inclusion
    assert validation[:enum] == Types.accepted_types()
  end
end
