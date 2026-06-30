defmodule Backplane.Auth.Schemas.User do
  @moduledoc "Local Backplane Auth user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.{PasswordCredential, Session}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_users" do
    field :email, :string
    field :name, :string
    field :active, :boolean, default: true
    field :last_login_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    has_one :password_credential, PasswordCredential
    has_many :sessions, Session

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :active, :last_login_at, :metadata])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email, name: :auth_users_lower_email_index)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
