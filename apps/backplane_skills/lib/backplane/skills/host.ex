defmodule Backplane.Skills.Host do
  @moduledoc """
  Ecto schema for durable host agent identities.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Skills.{HostAgentToken, HostAuthToken}

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_hosts" do
    field(:name, :string)

    has_many(:agent_tokens, HostAgentToken)

    many_to_many(:auth_tokens, HostAuthToken,
      join_through: HostAgentToken,
      join_keys: [host_id: :id, auth_token_id: :id]
    )

    timestamps()
  end

  @required_fields ~w(name)a

  @doc "Changeset for creating or updating a host agent identity."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(host, attrs) do
    host
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end
end
