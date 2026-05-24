defmodule Backplane.Skills.HostAgentToken do
  @moduledoc """
  Join schema assigning host agent auth tokens to durable host agents.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Skills.{Host, HostAuthToken}

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_host_agent_tokens" do
    belongs_to(:host, Host)
    belongs_to(:auth_token, HostAuthToken)

    timestamps()
  end

  @required_fields ~w(host_id auth_token_id)a

  @doc "Changeset for assigning one auth token to one host agent."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(agent_token, attrs) do
    agent_token
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:auth_token_id)
    |> foreign_key_constraint(:host_id)
    |> foreign_key_constraint(:auth_token_id)
  end
end
