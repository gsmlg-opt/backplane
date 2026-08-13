defmodule Backplane.Memory.Memories.RelationEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "bpm_memory_relation_evidence" do
    field(:relation_id, :binary_id, primary_key: true)
    field(:evidence_id, :binary_id, primary_key: true)
    field(:role, :string)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(join, attrs) do
    join
    |> cast(attrs, [:relation_id, :evidence_id, :role])
    |> validate_required([:relation_id, :evidence_id, :role])
    |> validate_inclusion(:role, ~w(source target))
    |> unique_constraint([:relation_id, :evidence_id])
  end
end
