defmodule Backplane.Repo.Migrations.AddSkillProtocolDeltas do
  use Ecto.Migration

  def up do
    alter table(:skill_protocol_state) do
      add(:change_transaction, :bigint)
    end

    create table(:skill_protocol_changes, primary_key: false) do
      add(:position, :bigserial, primary_key: true)
      add(:generation, :uuid, null: false)
      add(:previous_generation, :uuid, null: false)
      add(:skill_ids, {:array, :text}, null: false, default: [])
      add(:reset, :boolean, null: false, default: false)
    end

    create unique_index(:skill_protocol_changes, [:generation])
    create unique_index(:skill_protocol_changes, [:previous_generation])

    execute("""
    CREATE OR REPLACE FUNCTION #{qualified("notify_skill_protocol_change")}() RETURNS trigger AS $$
    DECLARE
      field_name text;
      changed boolean := TG_OP <> 'UPDATE';
      changed_skill text;
      old_generation uuid;
      new_generation uuid := gen_random_uuid();
      previous_transaction bigint;
      this_transaction bigint := txid_current();
    BEGIN
      IF TG_TABLE_NAME = 'system_settings' AND TG_OP <> 'TRUNCATE' THEN
        IF TG_OP = 'INSERT' AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'DELETE' AND OLD.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'UPDATE' AND OLD.key <> 'clients.auth_bypass.enabled'
                           AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        FOREACH field_name IN ARRAY TG_ARGV LOOP
          IF to_jsonb(OLD)->field_name IS DISTINCT FROM to_jsonb(NEW)->field_name THEN
            changed := true;
            EXIT;
          END IF;
        END LOOP;
      END IF;

      IF NOT changed THEN RETURN NULL; END IF;

      IF TG_OP <> 'TRUNCATE' THEN
        IF TG_TABLE_NAME = 'skills' THEN
          changed_skill := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
        ELSIF TG_TABLE_NAME = 'skill_revisions' THEN
          changed_skill := CASE WHEN TG_OP = 'DELETE' THEN OLD.skill_id ELSE NEW.skill_id END;
        END IF;
      END IF;

      SELECT generation, change_transaction INTO old_generation, previous_transaction
      FROM #{qualified("skill_protocol_state")} WHERE id = 1 FOR UPDATE;

      IF previous_transaction = this_transaction THEN
        UPDATE #{qualified("skill_protocol_changes")}
        SET generation = new_generation,
            skill_ids = CASE
              WHEN reset OR changed_skill IS NULL THEN ARRAY[]::text[]
              WHEN changed_skill = ANY(skill_ids) THEN skill_ids
              WHEN cardinality(skill_ids) >= 512 THEN ARRAY[]::text[]
              ELSE array_append(skill_ids, changed_skill)
            END,
            reset = reset OR changed_skill IS NULL OR
                    (NOT changed_skill = ANY(skill_ids) AND cardinality(skill_ids) >= 512)
        WHERE generation = old_generation;
      ELSE
        INSERT INTO #{qualified("skill_protocol_changes")}
          (generation, previous_generation, skill_ids, reset)
        VALUES
          (new_generation, old_generation,
           CASE WHEN changed_skill IS NULL THEN ARRAY[]::text[] ELSE ARRAY[changed_skill] END,
           changed_skill IS NULL);

        DELETE FROM #{qualified("skill_protocol_changes")}
        WHERE position IN (
          SELECT position FROM #{qualified("skill_protocol_changes")}
          ORDER BY position DESC OFFSET 256
        );
      END IF;

      UPDATE #{qualified("skill_protocol_state")}
      SET generation = new_generation, change_transaction = this_transaction WHERE id = 1;
      PERFORM pg_notify('backplane_skill_protocol_changed', '');
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION #{qualified("notify_skill_protocol_change")}() RETURNS trigger AS $$
    DECLARE
      field_name text;
      changed boolean := TG_OP <> 'UPDATE';
    BEGIN
      IF TG_TABLE_NAME = 'system_settings' AND TG_OP <> 'TRUNCATE' THEN
        IF TG_OP = 'INSERT' AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'DELETE' AND OLD.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'UPDATE' AND OLD.key <> 'clients.auth_bypass.enabled'
                           AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        FOREACH field_name IN ARRAY TG_ARGV LOOP
          IF to_jsonb(OLD)->field_name IS DISTINCT FROM to_jsonb(NEW)->field_name THEN
            changed := true;
            EXIT;
          END IF;
        END LOOP;
      END IF;

      IF changed THEN
        UPDATE #{qualified("skill_protocol_state")} SET generation = gen_random_uuid() WHERE id = 1;
        PERFORM pg_notify('backplane_skill_protocol_changed', '');
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    drop(table(:skill_protocol_changes))

    alter table(:skill_protocol_state) do
      remove(:change_transaction)
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
