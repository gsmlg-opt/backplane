defmodule Backplane.Skills.HostAuthToken do
  @moduledoc """
  Ecto schema for auth tokens that host agents use to connect to Backplane.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Skills.{Host, HostAgentToken}

  @type t :: %__MODULE__{}
  @derive_inspect_for_redacted_fields false
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_host_auth_tokens" do
    field(:name, :string)
    field(:token_hash, :string, redact: true)
    field(:encrypted_token, :binary, redact: true)

    has_one(:agent_token, HostAgentToken, foreign_key: :auth_token_id)

    many_to_many(:hosts, Host,
      join_through: HostAgentToken,
      join_keys: [auth_token_id: :id, host_id: :id]
    )

    timestamps()
  end

  @required_fields ~w(name token_hash encrypted_token)a

  @doc "Changeset for creating a host agent auth token."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(auth_token, attrs) do
    auth_token
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end
end
