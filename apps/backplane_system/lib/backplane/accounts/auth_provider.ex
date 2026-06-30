defmodule Backplane.Accounts.AuthProvider do
  @moduledoc "Upstream identity provider configuration for Backplane inbound OAuth."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Settings.Encryption

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @kinds ~w(oidc oauth2)

  @type t :: %__MODULE__{}

  schema "auth_providers" do
    field :slug, :string
    field :name, :string
    field :kind, :string
    field :issuer, :string
    field :authorization_url, :string
    field :token_url, :string
    field :userinfo_url, :string
    field :jwks_uri, :string
    field :client_id, :string
    field :client_secret, :string, virtual: true, redact: true
    field :encrypted_client_secret, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :allowed_email_domains, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :discovery, :map, default: %{}
    field :metadata, :map, default: %{}

    has_many :identities, Backplane.Accounts.UserIdentity, foreign_key: :provider_id

    timestamps()
  end

  @fields ~w(slug name kind issuer authorization_url token_url userinfo_url jwks_uri client_id scopes allowed_email_domains enabled discovery metadata)a

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @fields ++ [:client_secret])
    |> validate_required([:slug, :name, :kind, :client_id])
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:slug, &normalize_slug/1)
    |> put_encrypted_secret()
    |> validate_required([:encrypted_client_secret])
    |> unique_constraint(:slug)
  end

  def secret_changeset(provider, secret) when is_binary(secret) and byte_size(secret) > 0 do
    provider
    |> change()
    |> put_change(:encrypted_client_secret, Encryption.encrypt(secret))
    |> put_change(:client_secret, nil)
  end

  defp put_encrypted_secret(changeset) do
    case get_change(changeset, :client_secret) do
      secret when is_binary(secret) and byte_size(secret) > 0 ->
        changeset
        |> put_change(:encrypted_client_secret, Encryption.encrypt(secret))
        |> put_change(:client_secret, nil)

      _ ->
        changeset
    end
  end

  defp normalize_slug(slug) when is_binary(slug) do
    slug
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_slug(slug), do: slug
end
