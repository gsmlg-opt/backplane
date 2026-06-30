defmodule Backplane.Auth.Schemas.PasswordCredential do
  @moduledoc "Password credential for a local Backplane Auth user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_password_credentials" do
    field :password_hash, :string
    field :password_changed_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:user_id, :password_hash, :password_changed_at, :disabled_at])
    |> validate_required([:user_id, :password_hash])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
