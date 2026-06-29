defmodule Backplane.Repo.Migrations.CreateBorutaOauthTables do
  use Ecto.Migration

  # Boruta's generator emits historical migrations that create unprefixed
  # `clients`/`tokens`/`scopes` tables before renaming them to `oauth_*`.
  # Backplane already owns `clients`, so keep this as the squashed source of
  # truth and do not run `mix boruta.gen.migration` for the initial install.
  @grant_types [
    "client_credentials",
    "password",
    "authorization_code",
    "refresh_token",
    "implicit",
    "revoke",
    "introspect"
  ]

  def change do
    create table(:oauth_clients, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, default: "", null: false
      add :secret, :string, null: false
      add :confidential, :boolean, default: false, null: false
      add :authorize_scope, :boolean, default: false, null: false
      add :redirect_uris, {:array, :string}, default: [], null: false
      add :supported_grant_types, {:array, :string}, default: @grant_types, null: false
      add :pkce, :boolean, default: false, null: false
      add :public_refresh_token, :boolean, default: false, null: false
      add :public_revoke, :boolean, default: false, null: false
      add :access_token_ttl, :integer, default: 86_400, null: false
      add :authorization_code_ttl, :integer, default: 60, null: false
      add :id_token_ttl, :integer, default: 86_400, null: false
      add :refresh_token_ttl, :integer, default: 2_592_000, null: false
      add :id_token_signature_alg, :string, default: "RS512"
      add :id_token_kid, :string
      add :public_key, :text
      add :private_key, :text, null: false

      add :token_endpoint_auth_methods, {:array, :string},
        default: ["client_secret_basic", "client_secret_post"],
        null: false

      add :token_endpoint_jwt_auth_alg, :string, default: "HS256", null: false
      add :jwt_public_key, :text
      add :jwks_uri, :string
      add :userinfo_signed_response_alg, :string
      add :logo_uri, :string
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:oauth_scopes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :label, :string
      add :name, :string, default: ""
      add :public, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:oauth_clients_scopes) do
      add :client_id, references(:oauth_clients, type: :uuid, on_delete: :delete_all)
      add :scope_id, references(:oauth_scopes, type: :uuid, on_delete: :delete_all)
    end

    create table(:oauth_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :type, :string
      add :value, :string
      add :refresh_token, :string
      add :previous_token, :string
      add :previous_code, :string
      add :state, :string
      add :nonce, :string
      add :scope, :string, default: ""
      add :redirect_uri, :string
      add :expires_at, :integer
      add :revoked_at, :utc_datetime_usec
      add :refresh_token_revoked_at, :utc_datetime_usec
      add :code_challenge_hash, :string
      add :code_challenge_method, :string, default: "plain"
      add :client_id, references(:oauth_clients, type: :uuid, on_delete: :nilify_all)
      add :sub, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_clients, [:id, :secret])
    create index(:oauth_tokens, [:value])
    create unique_index(:oauth_tokens, [:client_id, :value])
    create unique_index(:oauth_tokens, [:client_id, :refresh_token])
    create unique_index(:oauth_scopes, [:name])
  end
end
