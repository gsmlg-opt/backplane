defmodule Backplane.Memory.Events.SchemaTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.{Event, Stream}

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
end
