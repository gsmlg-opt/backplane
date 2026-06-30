defmodule Backplane.Auth.Schemas.SigningKey do
  @moduledoc "JWT signing key material for Backplane Auth."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_signing_keys" do
    field :kid, :string
    field :private_jwk, :map
    field :public_jwk, :map
    field :active, :boolean, default: true
    field :retired_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(signing_key, attrs) do
    signing_key
    |> cast(attrs, [:kid, :private_jwk, :public_jwk, :active, :retired_at])
    |> validate_required([:kid, :private_jwk, :public_jwk, :active])
    |> unique_constraint(:kid)
  end
end
