defmodule Backplane.Memory.Projections.ProjectedSession do
  @moduledoc "Indexed canonical session row used by bounded lifecycle workers."

  use Ecto.Schema

  @primary_key {:subject_id, :string, autogenerate: false}
  schema "bpm_projected_sessions" do
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:session_id, :string)
    field(:project, :string)
    field(:agent_id, :string)
    field(:integration, :string)
    field(:status, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:last_event_at, :utc_datetime_usec)
    field(:source_sequence_max, :integer)
    field(:gap_count, :integer)
    field(:processing_version, :string)
    field(:input_revision, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
