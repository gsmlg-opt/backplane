defmodule Backplane.Skills.Host do
  @moduledoc """
  Ecto schema for host agents that sync assigned skills.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_hosts" do
    field(:name, :string)
    field(:hostname, :string)
    field(:token_hash, :string)
    field(:agent_version, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:status, :string, default: "unknown")
    field(:targets, :map, default: %{})
    field(:active, :boolean, default: true)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(name token_hash)a
  @optional_fields ~w(hostname agent_version last_seen_at status targets active metadata)a

  @doc "Changeset for creating or updating a host agent."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(host, attrs) do
    host
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end
end
