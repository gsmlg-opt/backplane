defmodule Backplane.Accounts.User do
  @moduledoc "Human identity used by Backplane inbound OAuth."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :email, :string
    field :name, :string
    field :active, :boolean, default: true
    field :last_login_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    has_many :identities, Backplane.Accounts.UserIdentity

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :active, :last_login_at, :metadata])
    |> validate_required([:email])
    |> update_change(:email, &normalize_email/1)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
