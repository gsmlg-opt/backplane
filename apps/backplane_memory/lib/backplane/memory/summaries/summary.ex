defmodule Backplane.Memory.Summaries.Summary do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_summaries" do
    field(:memory_space_id, :binary_id)
    field(:session_id, :string)
    field(:project, :string, default: "")
    field(:content, :string)
    field(:observation_count, :integer, default: 0)
    field(:subject_id, :string)
    field(:host_id, :string)
    field(:source_client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:agent_id, :string)
    field(:processing_version, :string)
    field(:input_revision, :string)
    field(:output_revision, :string)
    field(:source_complete, :boolean, default: true)
    field(:source_gap_count, :integer, default: 0)
    field(:source_gaps, :map, default: %{"ranges" => []})
    field(:superseded_at, :utc_datetime_usec)
    field(:superseded_by_input_revision, :string)
    timestamps()
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :session_id,
      :memory_space_id,
      :project,
      :content,
      :observation_count,
      :subject_id,
      :host_id,
      :source_client_id,
      :scope,
      :namespace,
      :agent_id,
      :processing_version,
      :input_revision,
      :output_revision,
      :source_complete,
      :source_gap_count,
      :source_gaps,
      :superseded_at,
      :superseded_by_input_revision
    ])
    |> validate_required([
      :session_id,
      :content,
      :subject_id,
      :host_id,
      :memory_space_id,
      :scope,
      :namespace,
      :processing_version,
      :input_revision,
      :output_revision
    ])
    |> validate_number(:observation_count, greater_than_or_equal_to: 0)
    |> validate_number(:source_gap_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:subject_id, :processing_version],
      name: :memory_summaries_subject_version_uniq
    )
  end
end
