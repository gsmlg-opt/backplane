defmodule Backplane.Repo.Migrations.CreateAuthAccounts do
  use Ecto.Migration

  def change do
    create table(:auth_users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :text, null: false
      add :name, :text
      add :active, :boolean, default: true, null: false
      add :last_login_at, :utc_datetime_usec
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_users, ["lower(email)"], name: :auth_users_lower_email_index)
    create index(:auth_users, [:active])

    create table(:auth_password_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id, references(:auth_users, type: :binary_id, on_delete: :delete_all), null: false

      add :password_hash, :text, null: false
      add :password_changed_at, :utc_datetime_usec
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_password_credentials, [:user_id])

    create table(:auth_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:auth_users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :text, null: false
      add :user_agent, :text
      add :ip, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_sessions, [:token_hash])
    create index(:auth_sessions, [:user_id])
    create index(:auth_sessions, [:expires_at])
    create index(:auth_sessions, [:revoked_at])

    create table(:auth_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event_type, :text, null: false
      add :actor_type, :text
      add :actor_id, :text
      add :target_type, :text
      add :target_id, :text
      add :severity, :text, default: "info", null: false
      add :ip, :text
      add :user_agent, :text
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:auth_audit_events, [:event_type])
    create index(:auth_audit_events, [:inserted_at])
    create index(:auth_audit_events, [:target_type, :target_id])
  end
end
