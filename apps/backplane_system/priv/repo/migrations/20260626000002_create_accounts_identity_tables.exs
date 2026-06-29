defmodule Backplane.Repo.Migrations.CreateAccountsIdentityTables do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :text, null: false
      add :name, :text
      add :active, :boolean, default: true, null: false
      add :last_login_at, :utc_datetime_usec
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:users, [:email])

    create table(:auth_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :slug, :text, null: false
      add :name, :text, null: false
      add :kind, :text, null: false
      add :issuer, :text
      add :authorization_url, :text
      add :token_url, :text
      add :userinfo_url, :text
      add :jwks_uri, :text
      add :client_id, :text, null: false
      add :encrypted_client_secret, :bytea, null: false
      add :scopes, {:array, :text}, default: [], null: false
      add :allowed_email_domains, {:array, :text}, default: [], null: false
      add :enabled, :boolean, default: true, null: false
      add :discovery, :map, default: %{}, null: false
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_providers, [:slug])
    create index(:auth_providers, [:enabled])

    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :provider_id, references(:auth_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject, :text, null: false
      add :email, :text
      add :name, :text
      add :raw_claims, :map, default: %{}, null: false
      add :last_login_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_identities, [:provider_id, :subject])
    create index(:user_identities, [:user_id])
    create index(:user_identities, [:email])
  end
end
