defmodule Backplane.Repo.Migrations.ReplaceMemoryExactCandidateIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY bpm_memories_exact_candidate_uniq
    ON #{qualified("bpm_memories")} (
      content_hash,
      scope,
      namespace,
      memory_type,
      (COALESCE(CASE WHEN jsonb_typeof(metadata->'project') = 'string' THEN metadata->>'project' ELSE '' END, '')),
      (COALESCE(client_id, ''))
    )
    WHERE deleted_at IS NULL
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_memories_dedup_uniq")}")
  end

  def down do
    execute(down_collision_preflight_sql())

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY bpm_memories_dedup_uniq
    ON #{qualified("bpm_memories")} (content_hash, scope)
    WHERE deleted_at IS NULL
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_memories_exact_candidate_uniq")}")
  end

  def down_collision_preflight_sql do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{qualified("bpm_memories")}
        WHERE deleted_at IS NULL
        GROUP BY content_hash, scope
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot restore bpm_memories_dedup_uniq: active (content_hash, scope) collisions exist'
          USING ERRCODE = '23505',
                HINT = 'Resolve or soft-delete colliding active memories before rolling back this migration.';
      END IF;
    END;
    $$
    """
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
