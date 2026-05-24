defmodule Backplane.Skills.HostStatus do
  @moduledoc """
  Ecto schema for host-reported skill installation status.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_host_statuses" do
    field(:host_id, :binary_id)
    field(:skill_id, :string)
    field(:skill_slug, :string)
    field(:skill_name, :string)
    field(:desired_version, :string)
    field(:installed_version, :string)
    field(:desired_checksum, :string)
    field(:installed_checksum, :string)
    field(:targets, {:array, :string}, default: [])
    field(:status, :string)
    field(:error, :string)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(host_id skill_name status)a

  @optional_fields ~w(skill_id skill_slug desired_version installed_version desired_checksum installed_checksum targets error metadata)a

  @doc "Changeset for creating or updating host-reported skill status."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(status, attrs) do
    status
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:host_id)
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint([:host_id, :skill_name])
  end
end
