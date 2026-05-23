defmodule Backplane.Repo.Migrations.RepairHostAgentAuthTokenAssignments do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:skill_host_agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :auth_token_id, references(:skill_host_auth_tokens, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:skill_host_agent_tokens, [:host_id])
    create_if_not_exists unique_index(:skill_host_agent_tokens, [:auth_token_id])

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'skill_hosts'
          AND column_name = 'auth_token_id'
      ) THEN
        INSERT INTO skill_host_agent_tokens (id, host_id, auth_token_id, inserted_at, updated_at)
        SELECT gen_random_uuid(), id, auth_token_id, now(), now()
        FROM skill_hosts
        WHERE auth_token_id IS NOT NULL
        ON CONFLICT (auth_token_id) DO NOTHING;
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE skill_hosts
      DROP COLUMN IF EXISTS auth_token_id,
      DROP COLUMN IF EXISTS hostname,
      DROP COLUMN IF EXISTS token_hash,
      DROP COLUMN IF EXISTS agent_version,
      DROP COLUMN IF EXISTS last_seen_at,
      DROP COLUMN IF EXISTS status,
      DROP COLUMN IF EXISTS targets,
      DROP COLUMN IF EXISTS active,
      DROP COLUMN IF EXISTS metadata
    """)

    execute("""
    ALTER TABLE skill_host_auth_tokens
      DROP COLUMN IF EXISTS active,
      DROP COLUMN IF EXISTS last_used_at,
      DROP COLUMN IF EXISTS metadata
    """)
  end

  def down do
    execute(
      "ALTER TABLE skill_host_auth_tokens ADD COLUMN IF NOT EXISTS active boolean DEFAULT true"
    )

    execute("""
    ALTER TABLE skill_host_auth_tokens
      ADD COLUMN IF NOT EXISTS last_used_at timestamp without time zone,
      ADD COLUMN IF NOT EXISTS metadata jsonb DEFAULT '{}'::jsonb
    """)

    alter table(:skill_hosts) do
      add_if_not_exists :hostname, :text
      add_if_not_exists :token_hash, :text, null: false, default: ""
      add_if_not_exists :auth_token_id, references(:skill_host_auth_tokens, type: :binary_id)
      add_if_not_exists :agent_version, :text
      add_if_not_exists :last_seen_at, :utc_datetime_usec
      add_if_not_exists :status, :text, null: false, default: "unknown"
      add_if_not_exists :targets, :map, null: false, default: %{}
      add_if_not_exists :active, :boolean, null: false, default: true
      add_if_not_exists :metadata, :map, null: false, default: %{}
    end

    execute("""
    UPDATE skill_hosts AS host
    SET auth_token_id = agent_token.auth_token_id
    FROM skill_host_agent_tokens AS agent_token
    WHERE agent_token.host_id = host.id
      AND host.auth_token_id IS NULL
    """)

    drop_if_exists unique_index(:skill_host_agent_tokens, [:auth_token_id])
    drop_if_exists index(:skill_host_agent_tokens, [:host_id])
    drop_if_exists table(:skill_host_agent_tokens)
  end
end
