defmodule Backplane.Skills.Revision do
  @moduledoc "Immutable persisted publication of one exact Skill bundle."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "skill_revisions" do
    field(:skill_id, :string, primary_key: true)
    field(:revision, :string, primary_key: true)
    field(:artifact_digest, :string)
    field(:manifest, :map)
    field(:blob_ref, :string)
    field(:published_at, :utc_datetime_usec)
    timestamps()
  end

  @fields ~w(skill_id revision artifact_digest manifest blob_ref published_at)a

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:skill_id, :revision])
    |> unique_constraint([:skill_id, :artifact_digest])
    |> foreign_key_constraint(:skill_id)
  end
end
