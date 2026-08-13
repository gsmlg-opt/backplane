defmodule Backplane.Memory.Memories.Evidence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "bpm_memory_evidence" do
    field(:memory_id, :binary_id)
    field(:source_event_id, :binary_id)
    field(:source_observation_id, :binary_id)
    field(:source_summary_id, :binary_id)
    field(:source_request_id, :binary_id)
    field(:source_crystal_id, :binary_id)
    field(:source_session_id, :string)
    field(:session_id, :string)
    field(:agent_id, :string)
    field(:host_id, :string)
    field(:evidence_kind, :string)
    field(:support_score, :float)
    field(:excerpt, :string)
    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, __schema__(:fields) -- [:id, :created_at])
    |> validate_required([:memory_id, :evidence_kind, :support_score])
    |> validate_inclusion(:evidence_kind, ~w(supports contradicts derives confirms applies))
    |> validate_number(:support_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:memory_id)
    |> foreign_key_constraint(:source_event_id)
    |> foreign_key_constraint(:source_observation_id)
    |> foreign_key_constraint(:source_summary_id)
    |> foreign_key_constraint(:source_request_id)
    |> foreign_key_constraint(:source_crystal_id)
    |> check_constraint(:evidence_kind, name: :bpm_memory_evidence_kind_check)
    |> check_constraint(:support_score, name: :bpm_memory_evidence_score_check)
    |> check_constraint(:source_event_id, name: :bpm_memory_evidence_source_check)
  end
end
