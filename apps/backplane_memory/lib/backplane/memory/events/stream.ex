defmodule Backplane.Memory.Events.Stream do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:stream_id, :string, autogenerate: false}
  schema "bpm_streams" do
    field :project, :string
    field :agent_id, :string
    field :host_id, :string
    field :client_id, :string
    field :session_id, :string
    field :run_id, :string
    field :next_sequence, :integer, default: 1
    field :last_window_sequence, :integer, default: 0
    field :last_event_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [:stream_id, :project, :agent_id, :host_id, :client_id, :session_id, :run_id])
    |> validate_required([:stream_id])
  end
end
