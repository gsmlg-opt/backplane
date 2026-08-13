defmodule Backplane.Memory.Memories.Relation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_relations" do
    field(:source_memory_id, :binary_id)
    field(:target_memory_id, :binary_id)
    field(:domain, :string)
    field(:relation_type, :string)
    field(:classification, :string)
    field(:confidence, :float)
    field(:status, :string, default: "candidate")
    field(:classifier_model, :string)
    field(:classifier_version, :string)
    field(:input_revision, :string)
    field(:correlation_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
  end

  def candidate_changeset(relation, attrs) do
    relation
    |> cast(attrs, [
      :source_memory_id,
      :target_memory_id,
      :domain,
      :relation_type,
      :classification,
      :confidence,
      :status,
      :classifier_model,
      :classifier_version,
      :input_revision,
      :correlation_id
    ])
    |> validate_required([
      :source_memory_id,
      :target_memory_id,
      :domain,
      :relation_type,
      :classification,
      :confidence,
      :status,
      :classifier_model,
      :classifier_version,
      :input_revision,
      :correlation_id
    ])
    |> validate_inclusion(:domain, ~w(lifecycle provenance knowledge))
    |> validate_inclusion(:relation_type, ~w(supersedes contradicts extends derives related))
    |> validate_inclusion(
      :classification,
      ~w(duplicate extension temporal_replacement contradiction unrelated)
    )
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint(
      [
        :source_memory_id,
        :target_memory_id,
        :domain,
        :relation_type,
        :classifier_model,
        :classifier_version,
        :input_revision
      ],
      name: :bpm_memory_relations_identity_uniq
    )
  end

  def resolution_changeset(relation, status) when status in ["confirmed", "rejected"] do
    change(relation, status: status, resolved_at: DateTime.utc_now())
  end
end
