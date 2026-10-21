defmodule Backplane.Repo.Migrations.AddMemoryHostAccess do
  use Ecto.Migration

  def up do
    execute("LOCK TABLE #{qualified("skill_hosts")} IN SHARE ROW EXCLUSIVE MODE")

    execute(
      "LOCK TABLE #{qualified("bpm_memory_space_entitlements")} IN SHARE ROW EXCLUSIVE MODE"
    )

    alter table(:bpm_memory_space_entitlements, prefix: prefix()) do
      add(:capabilities, {:array, :text}, null: false, default: [])
      add(:authority_version, :bigint, null: false, default: 1)
      add(:offline_read_lease_seconds, :integer, null: false, default: 0)
    end

    execute("""
    CREATE FUNCTION #{qualified("memory_access_sorted_capabilities")}(text[]) RETURNS text[]
    LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT ARRAY(SELECT DISTINCT item FROM unnest($1) item ORDER BY item) $$
    """)

    create constraint(:bpm_memory_space_entitlements, :bpm_memory_access_capabilities_check,
             prefix: prefix(),
             check:
               "capabilities <@ ARRAY['read','deliver','remember','forget']::text[] AND array_position(capabilities, NULL) IS NULL AND capabilities = #{qualified("memory_access_sorted_capabilities")}(capabilities) AND (NOT ('deliver' = ANY(capabilities)) OR 'read' = ANY(capabilities))"
           )

    create constraint(:bpm_memory_space_entitlements, :bpm_memory_access_version_check,
             prefix: prefix(),
             check: "authority_version > 0"
           )

    create constraint(:bpm_memory_space_entitlements, :bpm_memory_access_lease_check,
             prefix: prefix(),
             check:
               "offline_read_lease_seconds BETWEEN 0 AND 300 AND (offline_read_lease_seconds = 0 OR capabilities @> ARRAY['read','deliver']::text[])"
           )

    execute("""
    UPDATE #{qualified("bpm_memory_space_entitlements")} e
    SET capabilities = ARRAY['deliver','forget','read','remember']::text[]
    WHERE EXISTS (
      SELECT 1 FROM #{qualified("bpm_memory_space_legacy_aliases")} a
      JOIN #{qualified("bpm_memory_spaces")} s ON s.id = a.memory_space_id AND s.kind = 'private'
      WHERE a.alias_type = 'host' AND a.alias_value = 'host:' || e.host_id::text
        AND a.memory_space_id = e.memory_space_id)
    """)

    execute("""
    INSERT INTO #{qualified("bpm_memory_space_backfill_issues")}
      (id, source_table, source_id, reason, disposition, details, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'bpm_memory_space_entitlements', e.id::text,
      'shared_access_requires_disposition', 'pending',
      jsonb_build_object('memory_space_id', e.memory_space_id, 'host_id', e.host_id,
                        'scope', e.scope, 'namespace', e.namespace), now(), now()
    FROM #{qualified("bpm_memory_space_entitlements")} e WHERE e.capabilities = ARRAY[]::text[]
    ON CONFLICT (source_table, source_id) DO NOTHING
    """)

    create table(:bpm_memory_access_audits, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true)
      add(:request_id, :binary_id, null: false)
      add(:actor_kind, :text, null: false)
      add(:actor_ref, :string, size: 255)
      add(:action, :text, null: false)
      add(:access_id, :binary_id, null: false)
      add(:host_id, :binary_id, null: false)
      add(:memory_space_id, :binary_id, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:previous_status, :text)
      add(:new_status, :text, null: false)
      add(:previous_capabilities, {:array, :text})
      add(:new_capabilities, {:array, :text}, null: false)
      add(:previous_offline_read_lease_seconds, :integer)
      add(:new_offline_read_lease_seconds, :integer, null: false)
      add(:previous_authority_version, :bigint)
      add(:new_authority_version, :bigint, null: false)
      add(:reason, :string, size: 1024, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:bpm_memory_access_audits, [:access_id, :new_authority_version],
             unique: true,
             prefix: prefix()
           )

    create constraint(:bpm_memory_access_audits, :bpm_memory_access_audit_actor_check,
             prefix: prefix(),
             check: "actor_kind IN ('trusted_operator', 'system')"
           )

    create constraint(:bpm_memory_access_audits, :bpm_memory_access_audit_reason_check,
             prefix: prefix(),
             check: "length(btrim(reason)) > 0 AND new_authority_version > 0"
           )

    execute("""
    CREATE FUNCTION #{qualified("memory_access_audit_immutable")}() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'memory access audits are append-only'; END $$
    """)

    execute("""
    CREATE TRIGGER memory_access_audit_immutable BEFORE UPDATE OR DELETE
    ON #{qualified("bpm_memory_access_audits")} FOR EACH ROW
    EXECUTE FUNCTION #{qualified("memory_access_audit_immutable")}()
    """)
  end

  defp qualified(name), do: ~s|"#{prefix() || "public"}"."#{name}"|
end
