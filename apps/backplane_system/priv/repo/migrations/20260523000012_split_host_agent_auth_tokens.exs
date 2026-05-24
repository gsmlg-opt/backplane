defmodule Backplane.Repo.Migrations.SplitHostAgentAuthTokens do
  use Ecto.Migration

  def up do
    create table(:skill_host_auth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :token_hash, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_host_auth_tokens, [:name])

    create table(:skill_host_agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :auth_token_id, references(:skill_host_auth_tokens, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_host_agent_tokens, [:host_id])
    create unique_index(:skill_host_agent_tokens, [:auth_token_id])

    alter table(:skill_hosts) do
      remove :hostname
      remove :token_hash
      remove :agent_version
      remove :last_seen_at
      remove :status
      remove :targets
      remove :active
      remove :metadata
    end
  end

  def down do
    alter table(:skill_hosts) do
      add :hostname, :text
      add :token_hash, :text, null: false, default: ""
      add :agent_version, :text
      add :last_seen_at, :utc_datetime_usec
      add :status, :text, null: false, default: "unknown"
      add :targets, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}
    end

    drop_if_exists unique_index(:skill_host_agent_tokens, [:auth_token_id])
    drop_if_exists index(:skill_host_agent_tokens, [:host_id])
    drop table(:skill_host_agent_tokens)

    drop_if_exists unique_index(:skill_host_auth_tokens, [:name])
    drop table(:skill_host_auth_tokens)
  end
end
