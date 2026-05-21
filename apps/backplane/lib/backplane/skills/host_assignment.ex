defmodule Backplane.Skills.HostAssignment do
  @moduledoc """
  Ecto schema for assigning skills to host agents.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_host_assignments" do
    field(:host_id, :binary_id)
    field(:skill_id, :string)
    field(:targets, {:array, :string}, default: [])
    field(:enabled, :boolean, default: true)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(host_id skill_id)a
  @optional_fields ~w(targets enabled metadata)a

  @doc "Changeset for creating or updating a host skill assignment."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:host_id)
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint([:host_id, :skill_id])
  end
end
