defmodule Backplane.Skills.SkillVersion do
  @moduledoc """
  Ecto schema for skill version history.
  Only DB-sourced skills get version rows — git/local skills use their own VCS.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_versions" do
    field(:skill_id, :string)
    field(:version, :integer)
    field(:content_hash, :string)
    field(:content, :string)
    field(:metadata, :map, default: %{})
    field(:author, :string)
    field(:change_summary, :string)

    field(:inserted_at, :utc_datetime_usec)
  end

  @required_fields ~w(skill_id version content_hash content)a
  @optional_fields ~w(metadata author change_summary)a

  def changeset(skill_version, attrs) do
    skill_version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:skill_id, :version])
  end
end
