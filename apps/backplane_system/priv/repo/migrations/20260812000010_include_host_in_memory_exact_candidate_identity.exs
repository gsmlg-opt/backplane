defmodule Backplane.Repo.Migrations.IncludeHostInMemoryExactCandidateIdentity do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{quote_identifier("bpm_memories_exact_candidate_host_uniq")}
    ON #{qualified_table("bpm_memories")} (
      content_hash,
      host_id,
      scope,
      namespace,
      memory_type,
      (COALESCE(CASE WHEN jsonb_typeof(metadata->'project') = 'string' THEN metadata->>'project' ELSE '' END, '')),
      (COALESCE(client_id, ''))
    )
    WHERE deleted_at IS NULL
    """)

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS #{qualified_index("bpm_memories_exact_candidate_uniq")}"
    )
  end

  def down do
    execute(down_collision_preflight_sql())

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{quote_identifier("bpm_memories_exact_candidate_uniq")}
    ON #{qualified_table("bpm_memories")} (
      content_hash,
      scope,
      namespace,
      memory_type,
      (COALESCE(CASE WHEN jsonb_typeof(metadata->'project') = 'string' THEN metadata->>'project' ELSE '' END, '')),
      (COALESCE(client_id, ''))
    )
    WHERE deleted_at IS NULL
    """)

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS #{qualified_index("bpm_memories_exact_candidate_host_uniq")}"
    )
  end

  def down_collision_preflight_sql do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{qualified_table("bpm_memories")}
        WHERE deleted_at IS NULL
        GROUP BY
          content_hash,
          scope,
          namespace,
          memory_type,
          COALESCE(CASE WHEN jsonb_typeof(metadata->'project') = 'string' THEN metadata->>'project' ELSE '' END, ''),
          COALESCE(client_id, '')
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot restore bpm_memories_exact_candidate_uniq: active pre-host identity collisions exist'
          USING ERRCODE = '23505',
                HINT = 'Resolve or soft-delete colliding active memories before rolling back this migration.';
      END IF;
    END;
    $$
    """
  end

  defp qualified_table(table), do: qualify(table)
  defp qualified_index(index), do: qualify(index)

  defp qualify(name) do
    case prefix() do
      nil -> quote_identifier(name)
      prefix -> quote_identifier(prefix) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(identifier),
    do: ~s|"#{String.replace(identifier, "\"", "\"\"")}"|
end
