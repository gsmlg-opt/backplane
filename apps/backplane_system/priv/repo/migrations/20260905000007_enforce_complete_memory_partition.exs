defmodule Backplane.Repo.Migrations.EnforceCompleteMemoryPartition do
  use Ecto.Migration

  @string_fields ~w(host_id client_id scope namespace)
  @all_fields ["memory_space_id" | @string_fields]
  @cleanup_tables ~w(
    bpm_memory_relation_evidence
    memory_crystal_lessons
    memory_crystal_source_actions
    memory_crystal_source_events
    memory_crystal_source_summaries
    bpm_memory_evidence
    bpm_host_memory_revocations
    bpm_memory_relations
    memory_crystals
    bpm_memory_remember_requests
  )

  def up do
    Enum.each(statements(prefix()), &execute/1)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible migration: quarantined memory history and dependent provenance were permanently removed"
  end

  @doc false
  def enforce(repo, migration_prefix) do
    {:ok, :ok} =
      repo.transaction(fn ->
        Enum.each(statements(migration_prefix), &repo.query!/1)
        :ok
      end)

    :ok
  end

  defp statements(migration_prefix) do
    memories = qualified(migration_prefix, "bpm_memories")
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")

    [
      "LOCK TABLE #{memories} IN SHARE ROW EXCLUSIVE MODE",
      "DROP TABLE IF EXISTS pg_temp.bpm_incomplete_memory_ids",
      """
      CREATE TEMP TABLE bpm_incomplete_memory_ids ON COMMIT DROP AS
      SELECT id
      FROM #{memories}
      WHERE memory_space_id IS NULL
         OR nullif(btrim(host_id), '') IS NULL
         OR nullif(btrim(client_id), '') IS NULL
         OR nullif(btrim(scope), '') IS NULL
         OR nullif(btrim(namespace), '') IS NULL
      """,
      """
      INSERT INTO #{issues}
        (source_table, source_id, reason, disposition, details, resolved_at, inserted_at, updated_at)
      SELECT 'bpm_memories', memory.id::text, 'incomplete_partition', 'pending',
             jsonb_build_object(
               'memory_space_id', memory.memory_space_id,
               'host_id', memory.host_id,
               'client_id', memory.client_id,
               'scope', memory.scope,
               'namespace', memory.namespace,
               'missing_fields', to_jsonb(array_remove(ARRAY[
                 CASE WHEN memory.memory_space_id IS NULL THEN 'memory_space_id' END,
                 CASE WHEN nullif(btrim(memory.host_id), '') IS NULL THEN 'host_id' END,
                 CASE WHEN nullif(btrim(memory.client_id), '') IS NULL THEN 'client_id' END,
                 CASE WHEN nullif(btrim(memory.scope), '') IS NULL THEN 'scope' END,
                 CASE WHEN nullif(btrim(memory.namespace), '') IS NULL THEN 'namespace' END
               ]::text[], NULL))
             ),
             NULL, now(), now()
      FROM #{memories} AS memory
      JOIN bpm_incomplete_memory_ids AS invalid ON invalid.id = memory.id
      ON CONFLICT (source_table, source_id) DO UPDATE
      SET reason = EXCLUDED.reason,
          disposition = 'pending',
          details = EXCLUDED.details,
          resolved_at = NULL,
          updated_at = now()
      """
    ] ++
      Enum.map(@cleanup_tables, &set_user_triggers_sql(migration_prefix, &1, "DISABLE")) ++
      dependent_cleanup_statements(migration_prefix) ++
      [
        "UPDATE #{memories} SET superseded_by = NULL WHERE superseded_by IN (SELECT id FROM bpm_incomplete_memory_ids)",
        "DELETE FROM #{memories} WHERE id IN (SELECT id FROM bpm_incomplete_memory_ids)"
      ] ++
      Enum.map(@cleanup_tables, &set_user_triggers_sql(migration_prefix, &1, "ENABLE")) ++
      Enum.map(@all_fields, fn field ->
        "ALTER TABLE #{memories} ALTER COLUMN #{quote_name(field)} SET NOT NULL"
      end) ++
      Enum.flat_map(@string_fields, fn field ->
        constraint = constraint_name(field)

        [
          add_constraint_if_missing_sql(migration_prefix, constraint, field),
          "ALTER TABLE #{memories} VALIDATE CONSTRAINT #{quote_name(constraint)}"
        ]
      end)
  end

  defp dependent_cleanup_statements(migration_prefix) do
    invalid = "SELECT id FROM bpm_incomplete_memory_ids"

    [
      delete_if_present(
        migration_prefix,
        "bpm_memory_relation_evidence",
        "relation_id IN (SELECT id FROM %RELATIONS% WHERE source_memory_id IN (#{invalid}) OR target_memory_id IN (#{invalid})) OR evidence_id IN (SELECT evidence.id FROM %EVIDENCE% AS evidence WHERE evidence.memory_id IN (#{invalid}) OR evidence.source_request_id IN (SELECT id FROM %REQUESTS% WHERE memory_id IN (#{invalid})) OR evidence.source_crystal_id IN (SELECT id FROM %CRYSTALS% WHERE memory_id IN (#{invalid})))",
        %{
          "%RELATIONS%" => qualified(migration_prefix, "bpm_memory_relations"),
          "%EVIDENCE%" => qualified(migration_prefix, "bpm_memory_evidence"),
          "%REQUESTS%" => qualified(migration_prefix, "bpm_memory_remember_requests"),
          "%CRYSTALS%" => qualified(migration_prefix, "memory_crystals")
        }
      ),
      delete_if_present(
        migration_prefix,
        "memory_crystal_lessons",
        "lesson_memory_id IN (#{invalid}) OR crystal_id IN (SELECT id FROM %CRYSTALS% WHERE memory_id IN (#{invalid}))",
        %{"%CRYSTALS%" => qualified(migration_prefix, "memory_crystals")}
      ),
      delete_if_present(
        migration_prefix,
        "bpm_memory_evidence",
        "memory_id IN (#{invalid}) OR source_request_id IN (SELECT id FROM %REQUESTS% WHERE memory_id IN (#{invalid})) OR source_crystal_id IN (SELECT id FROM %CRYSTALS% WHERE memory_id IN (#{invalid}))",
        %{
          "%REQUESTS%" => qualified(migration_prefix, "bpm_memory_remember_requests"),
          "%CRYSTALS%" => qualified(migration_prefix, "memory_crystals")
        }
      ),
      delete_if_present(
        migration_prefix,
        "bpm_host_memory_revocations",
        "memory_id IN (#{invalid}) OR source_request_id IN (SELECT id FROM %REQUESTS% WHERE memory_id IN (#{invalid}))",
        %{"%REQUESTS%" => qualified(migration_prefix, "bpm_memory_remember_requests")}
      ),
      delete_if_present(
        migration_prefix,
        "bpm_memory_relations",
        "source_memory_id IN (#{invalid}) OR target_memory_id IN (#{invalid})"
      ),
      delete_if_present(migration_prefix, "memory_crystals", "memory_id IN (#{invalid})"),
      delete_if_present(
        migration_prefix,
        "bpm_memory_remember_requests",
        "memory_id IN (#{invalid})"
      )
    ]
  end

  defp set_user_triggers_sql(migration_prefix, table_name, action) do
    table = qualified(migration_prefix, table_name)
    schema = escape_literal(migration_prefix || "public")

    """
    DO $$
    BEGIN
      IF to_regclass('#{schema}.#{escape_literal(table_name)}') IS NOT NULL THEN
        ALTER TABLE #{table} #{action} TRIGGER USER;
      END IF;
    END;
    $$
    """
  end

  defp delete_if_present(migration_prefix, table_name, condition, replacements \\ %{}) do
    table = qualified(migration_prefix, table_name)
    schema = escape_literal(migration_prefix || "public")

    condition =
      Enum.reduce(replacements, condition, fn {from, to}, sql -> String.replace(sql, from, to) end)

    delete = escape_literal("DELETE FROM #{table} WHERE #{condition}")

    """
    DO $$
    BEGIN
      IF to_regclass('#{schema}.#{escape_literal(table_name)}') IS NOT NULL THEN
        EXECUTE '#{delete}';
      END IF;
    END;
    $$
    """
  end

  defp add_constraint_if_missing_sql(migration_prefix, constraint, field) do
    table = qualified(migration_prefix, "bpm_memories")
    schema = escape_literal(migration_prefix || "public")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = '#{schema}.bpm_memories'::regclass
          AND conname = '#{escape_literal(constraint)}'
      ) THEN
        ALTER TABLE #{table}
          ADD CONSTRAINT #{quote_name(constraint)}
          CHECK (length(btrim(#{quote_name(field)})) > 0) NOT VALID;
      END IF;
    END;
    $$
    """
  end

  defp constraint_name(field), do: "bpm_memories_complete_#{field}_check"

  defp qualified(migration_prefix, table_name) do
    [migration_prefix || "public", table_name]
    |> Enum.map_join(".", &quote_name/1)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp escape_literal(value), do: String.replace(value, "'", "''")
end
