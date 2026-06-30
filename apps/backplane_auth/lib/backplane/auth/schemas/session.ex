defmodule Backplane.Auth.Schemas.Session do
  @moduledoc "Browser login session for Backplane Auth authorization flows."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_sessions" do
    field :token_hash, :string
    field :user_agent, :string
    field :ip, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, User

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :user_agent, :ip, :expires_at, :revoked_at, :metadata])
    |> validate_required([:user_id, :token_hash, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end
end
