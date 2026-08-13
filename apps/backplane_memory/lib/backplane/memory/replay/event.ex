defmodule Backplane.Memory.Replay.Event do
  use Ecto.Schema
  @primary_key false
  schema "memory_replay_events" do
    field(:subject_id, :string, primary_key: true)
    field(:input_revision, :string, primary_key: true)
    field(:position, :integer, primary_key: true)
    field(:event_id, :binary_id)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:session_id, :string)
    field(:source_sequence, :integer)
    field(:kind, :string)
    field(:event_type, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:detail, :map)
    field(:processing_version, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
