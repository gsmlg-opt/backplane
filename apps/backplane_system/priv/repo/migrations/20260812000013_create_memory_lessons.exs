defmodule Backplane.Repo.Migrations.CreateMemoryLessons do
  use Ecto.Migration

  def up do
    create table(:memory_lessons, primary_key: false) do
      add(:memory_id, references(:bpm_memories, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:status, :text, null: false)
      add(:context, :text)
      add(:source_kind, :text, null: false)
      add(:reinforcement_count, :bigint, null: false, default: 0)
      add(:contradiction_count, :bigint, null: false, default: 0)
      add(:decay_rate, :float, null: false, default: 0.0)
      add(:last_reinforced_at, :utc_datetime_usec)
      add(:last_applied_at, :utc_datetime_usec)
      add(:last_decayed_at, :utc_datetime_usec)
      add(:promoted_at, :utc_datetime_usec)
      add(:promoted_by, :text)
      add(:promotion_reason, :text)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:memory_lessons, :memory_lessons_status_check,
        check: "status IN ('candidate', 'active', 'disputed', 'superseded', 'archived')"
      )
    )

    create(
      constraint(:memory_lessons, :memory_lessons_source_kind_check,
        check: "source_kind IN ('manual', 'correction', 'crystal', 'consolidation')"
      )
    )

    create(
      constraint(:memory_lessons, :memory_lessons_counts_nonnegative,
        check: "reinforcement_count >= 0 AND contradiction_count >= 0"
      )
    )

    create(
      constraint(:memory_lessons, :memory_lessons_decay_rate_nonnegative,
        check: "decay_rate >= 0"
      )
    )

    execute("""
    CREATE FUNCTION #{function_name(:memory_active_lesson_requires_evidence)}()
    RETURNS trigger AS $$
    DECLARE
      checked_memory_id uuid;
    BEGIN
      FOREACH checked_memory_id IN ARRAY ARRAY[OLD.memory_id, NEW.memory_id]
      LOOP
        CONTINUE WHEN checked_memory_id IS NULL;

        IF EXISTS (
          SELECT 1 FROM #{table_name(:memory_lessons)}
          WHERE memory_id = checked_memory_id AND status = 'active'
        ) AND NOT EXISTS (
          SELECT 1 FROM #{table_name(:bpm_memory_evidence)} WHERE memory_id = checked_memory_id
        ) THEN
          RAISE EXCEPTION 'active lesson % requires evidence', checked_memory_id
            USING ERRCODE = '23514', CONSTRAINT = 'memory_active_lesson_evidence_check';
        END IF;
      END LOOP;

      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER memory_active_lesson_evidence_from_lesson
    AFTER INSERT OR UPDATE OF status, memory_id ON #{table_name(:memory_lessons)}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{function_name(:memory_active_lesson_requires_evidence)}()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER memory_active_lesson_evidence_from_evidence
    AFTER DELETE OR UPDATE OF memory_id ON #{table_name(:bpm_memory_evidence)}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{function_name(:memory_active_lesson_requires_evidence)}()
    """)

    execute("""
    CREATE FUNCTION #{function_name(:memory_lesson_requires_procedural_parent)}()
    RETURNS trigger AS $$
    DECLARE
      checked_memory_id uuid;
    BEGIN
      FOREACH checked_memory_id IN ARRAY ARRAY[
        COALESCE((to_jsonb(OLD)->>'memory_id')::uuid, (to_jsonb(OLD)->>'id')::uuid),
        COALESCE((to_jsonb(NEW)->>'memory_id')::uuid, (to_jsonb(NEW)->>'id')::uuid)
      ]
      LOOP
        CONTINUE WHEN checked_memory_id IS NULL;

        IF EXISTS (
          SELECT 1 FROM #{table_name(:memory_lessons)} WHERE memory_id = checked_memory_id
        )
          AND NOT EXISTS (
            SELECT 1 FROM #{table_name(:bpm_memories)}
            WHERE id = checked_memory_id AND memory_type = 'procedural'
          )
        THEN
          RAISE EXCEPTION 'lesson % requires procedural memory parent', checked_memory_id
            USING ERRCODE = '23514', CONSTRAINT = 'memory_lesson_procedural_parent_check';
        END IF;
      END LOOP;

      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER memory_lesson_procedural_from_lesson
    AFTER INSERT OR UPDATE OF memory_id ON #{table_name(:memory_lessons)}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{function_name(:memory_lesson_requires_procedural_parent)}()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER memory_lesson_procedural_from_memory
    AFTER UPDATE OF memory_type ON #{table_name(:bpm_memories)}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{function_name(:memory_lesson_requires_procedural_parent)}()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS memory_lesson_procedural_from_memory ON #{table_name(:bpm_memories)}"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_lesson_procedural_from_lesson ON #{table_name(:memory_lessons)}"
    )

    execute(
      "DROP FUNCTION IF EXISTS #{function_name(:memory_lesson_requires_procedural_parent)}()"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_active_lesson_evidence_from_evidence ON #{table_name(:bpm_memory_evidence)}"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_active_lesson_evidence_from_lesson ON #{table_name(:memory_lessons)}"
    )

    execute("DROP FUNCTION IF EXISTS #{function_name(:memory_active_lesson_requires_evidence)}()")
    drop(table(:memory_lessons))
  end

  defp table_name(name), do: qualified_name(name)
  defp function_name(name), do: qualified_name(name)

  defp qualified_name(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier) do
    escaped = identifier |> to_string() |> String.replace("\"", "\"\"")
    "\"#{escaped}\""
  end
end
