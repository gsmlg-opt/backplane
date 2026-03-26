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
    field :name, :string
    field :description, :string, default: ""
    field :tags, {:array, :string}, default: []
    field :tools, {:array, :string}, default: []
    field :model, :string
    field :version, :string, default: "1.0.0"
    field :content, :string
    field :content_hash, :string
    field :source, :string
    field :enabled, :boolean, default: true

    timestamps()
  end

  @required_fields ~w(id name content content_hash source)a
  @optional_fields ~w(description tags tools model version enabled)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, ~w(content content_hash description tags tools model version enabled)a)
  end
end
