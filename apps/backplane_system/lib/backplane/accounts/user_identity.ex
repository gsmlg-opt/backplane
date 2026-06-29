defmodule Backplane.Accounts.UserIdentity do
  @moduledoc "Link between a Backplane user and an upstream provider subject."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "user_identities" do
    belongs_to :user, Backplane.Accounts.User
    belongs_to :provider, Backplane.Accounts.AuthProvider

    field :subject, :string
    field :email, :string
    field :name, :string
    field :raw_claims, :map, default: %{}
    field :last_login_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider_id, :subject, :email, :name, :raw_claims, :last_login_at])
    |> validate_required([:user_id, :provider_id, :subject])
    |> update_change(:email, &normalize_email/1)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :subject])
  end

  def claim_changeset(identity, attrs) do
    identity
    |> cast(attrs, [:email, :name, :raw_claims, :last_login_at])
    |> update_change(:email, &normalize_email/1)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
