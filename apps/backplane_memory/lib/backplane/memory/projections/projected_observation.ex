defmodule Backplane.Memory.Projections.ProjectedObservation do
  @moduledoc "Indexed row-shaped production projection for one canonical captured event."

  use Ecto.Schema

  @primary_key {:event_id, :binary_id, autogenerate: false}
  schema "bpm_projected_observations" do
    field(:subject_id, :string)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:session_id, :string)
    field(:project, :string)
    field(:agent_id, :string)
    field(:source_sequence, :integer)
    field(:event_type, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:tool_name, :string)
    field(:content, :string)
    field(:message, :string)
    field(:importance, :integer)
    field(:is_error, :boolean)
    field(:file_paths, {:array, :string})
    field(:commit_hash, :string)
    field(:processing_version, :string)
    field(:input_revision, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
