defmodule Backplane.Skills.Skill do
  @moduledoc """
  Ecto schema for the skills table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skills" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:tags, {:array, :string}, default: [])
    field(:content, :string)
    field(:content_hash, :string)
    field(:enabled, :boolean, default: true)

    timestamps()
  end

  @required_fields ~w(id name content)a
  @optional_fields ~w(description tags content_hash enabled)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @spec update_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, ~w(content content_hash description tags enabled)a)
  end
end
