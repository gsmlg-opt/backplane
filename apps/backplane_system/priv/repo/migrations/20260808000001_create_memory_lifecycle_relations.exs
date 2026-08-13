defmodule Backplane.Repo.Migrations.CreateMemoryLifecycleRelations do
  use Ecto.Migration

  def up do
    alter table(:bpm_memories), do: add(:lifecycle_state, :text, null: false, default: "active")

    execute("""
    UPDATE #{qualified("bpm_memories")} SET lifecycle_state = CASE
      WHEN deleted_at IS NOT NULL THEN 'tombstoned'
      WHEN superseded_by IS NOT NULL THEN 'superseded'
      ELSE 'active'
    END
    """)

    create constraint(:bpm_memories, :bpm_memories_lifecycle_state_check,
             check:
               "lifecycle_state IN ('candidate','active','disputed','superseded','archived','tombstoned')"
           )

    create constraint(:bpm_memories, :bpm_memories_superseded_self_check,
             check: "superseded_by IS NULL OR superseded_by <> id"
           )

    create constraint(:bpm_memories, :bpm_memories_lifecycle_columns_check,
             check:
               "(lifecycle_state <> 'superseded' OR superseded_by IS NOT NULL) AND (superseded_by IS NULL OR lifecycle_state IN ('superseded','tombstoned')) AND (lifecycle_state = 'tombstoned') = (deleted_at IS NOT NULL)"
           )

    execute(
      "ALTER TABLE #{qualified("bpm_memories")} ADD CONSTRAINT bpm_memories_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES #{qualified("bpm_memories")}(id) ON DELETE RESTRICT NOT VALID"
    )

    execute(
      "ALTER TABLE #{qualified("bpm_memories")} VALIDATE CONSTRAINT bpm_memories_superseded_by_fkey"
    )

    create index(:bpm_memories, [:scope, :lifecycle_state, :memory_type],
             name: :bpm_memories_scope_lifecycle_type_idx
           )

    create index(:bpm_memories, [:superseded_by],
             where: "superseded_by IS NOT NULL",
             name: :bpm_memories_superseded_by_idx
           )

    create table(:bpm_memory_relations, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:source_memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:target_memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:domain, :text, null: false)
      add(:relation_type, :text, null: false)
      add(:classification, :text, null: false)
      add(:confidence, :float, null: false)
      add(:status, :text, null: false, default: "candidate")
      add(:classifier_model, :text, null: false)
      add(:classifier_version, :text, null: false)
      add(:input_revision, :text, null: false)
      add(:correlation_id, :binary_id, null: false)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:resolved_at, :utc_datetime_usec)
    end

    create constraint(:bpm_memory_relations, :bpm_memory_relations_values_check,
             check:
               "source_memory_id <> target_memory_id AND domain IN ('lifecycle','provenance','knowledge') AND relation_type IN ('supersedes','contradicts','extends','derives','related') AND classification IN ('duplicate','extension','temporal_replacement','contradiction','unrelated') AND confidence >= 0.0 AND confidence <= 1.0 AND status IN ('candidate','confirmed','rejected')"
           )

    create constraint(:bpm_memory_relations, :bpm_memory_relations_resolution_check,
             check:
               "(status = 'candidate' AND resolved_at IS NULL) OR (status IN ('confirmed','rejected') AND resolved_at IS NOT NULL)"
           )

    create constraint(:bpm_memory_relations, :bpm_memory_relations_classification_mapping_check,
             check:
               "(classification = 'contradiction' AND domain = 'lifecycle' AND relation_type = 'contradicts' AND source_memory_id < target_memory_id) OR (classification = 'temporal_replacement' AND domain = 'lifecycle' AND relation_type = 'supersedes') OR (classification = 'extension' AND domain = 'knowledge' AND relation_type = 'extends') OR (classification IN ('duplicate','unrelated') AND domain = 'knowledge' AND relation_type = 'related' AND source_memory_id < target_memory_id)"
           )

    create constraint(:bpm_memory_relations, :bpm_memory_relations_identity_nonempty,
             check:
               "btrim(classifier_model) <> '' AND btrim(classifier_version) <> '' AND btrim(input_revision) <> ''"
           )

    create unique_index(
             :bpm_memory_relations,
             [
               :source_memory_id,
               :target_memory_id,
               :domain,
               :relation_type,
               :classifier_model,
               :classifier_version,
               :input_revision
             ],
             name: :bpm_memory_relations_identity_uniq
           )

    create index(:bpm_memory_relations, [:source_memory_id, :domain, :status])
    create index(:bpm_memory_relations, [:target_memory_id, :domain, :status])

    create index(:bpm_memory_relations, [:domain, :relation_type, :created_at],
             where: "status = 'candidate'",
             name: :bpm_memory_relations_pending_idx
           )

    create unique_index(:bpm_memory_relations, [:source_memory_id],
             where: "status = 'confirmed' AND relation_type = 'supersedes'",
             name: :bpm_memory_relations_confirmed_supersession_uniq
           )

    create table(:bpm_memory_relation_evidence, primary_key: false) do
      add(:relation_id, references(:bpm_memory_relations, type: :binary_id, on_delete: :restrict),
        primary_key: true
      )

      add(:evidence_id, references(:bpm_memory_evidence, type: :binary_id, on_delete: :restrict),
        primary_key: true
      )

      add(:role, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create constraint(:bpm_memory_relation_evidence, :bpm_memory_relation_evidence_role_check,
             check: "role IN ('source','target')"
           )

    create index(:bpm_memory_relation_evidence, [:evidence_id])

    execute("""
    CREATE FUNCTION #{qualified("bpm_validate_relation_evidence")}() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE endpoint uuid; owner uuid;
    BEGIN
      SELECT CASE WHEN NEW.role = 'source' THEN source_memory_id ELSE target_memory_id END
        INTO endpoint FROM #{qualified("bpm_memory_relations")} WHERE id = NEW.relation_id;
      SELECT memory_id INTO owner FROM #{qualified("bpm_memory_evidence")} WHERE id = NEW.evidence_id;
      IF endpoint IS NULL OR owner IS DISTINCT FROM endpoint THEN
        RAISE EXCEPTION 'relation evidence must belong to the selected endpoint' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END; $$
    """)

    execute(
      "CREATE TRIGGER bpm_memory_relation_evidence_owner BEFORE INSERT ON #{qualified("bpm_memory_relation_evidence")} FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_validate_relation_evidence")}()"
    )

    execute("""
    CREATE FUNCTION #{qualified("bpm_require_relation_endpoint_evidence")}() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE source_count integer; target_count integer;
    BEGIN
      SELECT count(*) FILTER (WHERE role = 'source'), count(*) FILTER (WHERE role = 'target')
        INTO source_count, target_count
        FROM #{qualified("bpm_memory_relation_evidence")}
        WHERE relation_id = NEW.id;
      IF source_count < 1 OR target_count < 1 THEN
        RAISE EXCEPTION 'memory relation requires source and target evidence' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END; $$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER bpm_memory_relations_evidence_required
    AFTER INSERT ON #{qualified("bpm_memory_relations")}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_require_relation_endpoint_evidence")}()
    """)

    execute("""
    CREATE FUNCTION #{qualified("bpm_guard_memory_relation_mutation")}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP IN ('DELETE','TRUNCATE') THEN
        RAISE EXCEPTION 'memory relation history is immutable' USING ERRCODE = '55000';
      END IF;
      IF OLD.status = 'candidate' AND NEW.status IN ('confirmed','rejected')
         AND NEW.resolved_at IS NOT NULL
         AND (to_jsonb(NEW) - ARRAY['status','resolved_at']) = (to_jsonb(OLD) - ARRAY['status','resolved_at']) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'memory relation history is immutable' USING ERRCODE = '55000';
    END; $$
    """)

    execute(
      "CREATE TRIGGER bpm_memory_relations_guard BEFORE UPDATE OR DELETE ON #{qualified("bpm_memory_relations")} FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_guard_memory_relation_mutation")}()"
    )

    execute(
      "CREATE TRIGGER bpm_memory_relations_guard_truncate BEFORE TRUNCATE ON #{qualified("bpm_memory_relations")} FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("bpm_guard_memory_relation_mutation")}()"
    )

    for table <- ["bpm_memory_relation_evidence", "memory_audit_log"] do
      execute(
        "CREATE TRIGGER #{table}_immutable_row BEFORE UPDATE OR DELETE ON #{qualified(table)} FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()"
      )

      execute(
        "CREATE TRIGGER #{table}_immutable_truncate BEFORE TRUNCATE ON #{qualified(table)} FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()"
      )
    end
  end

  def down do
    for table <- ["memory_audit_log", "bpm_memory_relation_evidence"] do
      execute("DROP TRIGGER IF EXISTS #{table}_immutable_truncate ON #{qualified(table)}")
      execute("DROP TRIGGER IF EXISTS #{table}_immutable_row ON #{qualified(table)}")
    end

    execute(
      "DROP TRIGGER IF EXISTS bpm_memory_relations_evidence_required ON #{qualified("bpm_memory_relations")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS bpm_memory_relations_guard_truncate ON #{qualified("bpm_memory_relations")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS bpm_memory_relations_guard ON #{qualified("bpm_memory_relations")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS bpm_memory_relation_evidence_owner ON #{qualified("bpm_memory_relation_evidence")}"
    )

    execute("DROP INDEX IF EXISTS #{qualified("bpm_memory_relation_evidence_evidence_id_index")}")

    for constraint <- [
          "bpm_memory_relation_evidence_role_check",
          "bpm_memory_relation_evidence_relation_id_fkey",
          "bpm_memory_relation_evidence_evidence_id_fkey",
          "bpm_memory_relation_evidence_pkey"
        ] do
      execute(
        "ALTER TABLE #{qualified("bpm_memory_relation_evidence")} DROP CONSTRAINT IF EXISTS #{constraint}"
      )
    end

    drop table(:bpm_memory_relation_evidence)

    for index <- [
          "bpm_memory_relations_confirmed_supersession_uniq",
          "bpm_memory_relations_pending_idx",
          "bpm_memory_relations_target_memory_id_domain_status_index",
          "bpm_memory_relations_source_memory_id_domain_status_index",
          "bpm_memory_relations_identity_uniq"
        ] do
      execute("DROP INDEX IF EXISTS #{qualified(index)}")
    end

    for constraint <- [
          "bpm_memory_relations_identity_nonempty",
          "bpm_memory_relations_classification_mapping_check",
          "bpm_memory_relations_resolution_check",
          "bpm_memory_relations_values_check",
          "bpm_memory_relations_source_memory_id_fkey",
          "bpm_memory_relations_target_memory_id_fkey",
          "bpm_memory_relations_pkey"
        ] do
      execute(
        "ALTER TABLE #{qualified("bpm_memory_relations")} DROP CONSTRAINT IF EXISTS #{constraint}"
      )
    end

    drop table(:bpm_memory_relations)
    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_guard_memory_relation_mutation")}()")
    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_require_relation_endpoint_evidence")}()")
    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_validate_relation_evidence")}()")

    execute("DROP INDEX IF EXISTS #{qualified("bpm_memories_superseded_by_idx")}")
    execute("DROP INDEX IF EXISTS #{qualified("bpm_memories_scope_lifecycle_type_idx")}")

    execute(
      "ALTER TABLE #{qualified("bpm_memories")} DROP CONSTRAINT IF EXISTS bpm_memories_superseded_by_fkey"
    )

    for constraint <- [
          "bpm_memories_lifecycle_columns_check",
          "bpm_memories_superseded_self_check",
          "bpm_memories_lifecycle_state_check"
        ] do
      execute("ALTER TABLE #{qualified("bpm_memories")} DROP CONSTRAINT IF EXISTS #{constraint}")
    end

    alter table(:bpm_memories), do: remove(:lifecycle_state)
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
