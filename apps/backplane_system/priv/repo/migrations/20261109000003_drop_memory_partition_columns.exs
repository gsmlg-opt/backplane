defmodule Backplane.Repo.Migrations.DropMemoryPartitionColumns do
  use Ecto.Migration

  # Capture tables lose their memory-space ownership. Existing capture data is disposable.
  @tables ~w(
    bpm_events
    bpm_streams
    bpm_projection_states
    bpm_projection_snapshots
    bpm_projection_repair_frontiers
    bpm_projected_sessions
    bpm_projected_observations
  )
  @partition_columns ~w(memory_space_id scope namespace)

  def up do
    p = quoted_prefix()
    schema = String.replace(prefix() || "public", "'", "''")
    tables = "ARRAY[#{Enum.map_join(@tables, ", ", &"'#{&1}'")}]::text[]"

    # Retired tables (dropped later) still reference capture rows; detach them so the
    # capture tables can be truncated without cascading into their immutability guards.
    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT con.conname, rel.relname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_class ref ON ref.oid = con.confrelid
        JOIN pg_namespace n ON n.oid = ref.relnamespace
        WHERE con.contype = 'f'
          AND n.nspname = '#{schema}'
          AND rel.relnamespace = ref.relnamespace
          AND ref.relname = ANY(#{tables})
          AND rel.relname <> ALL(#{tables})
      LOOP
        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', '#{schema}', r.relname, r.conname);
      END LOOP;
    END
    $$
    """)

    # The truncate guard rejects truncation while captured events exist.
    execute("ALTER TABLE #{p}.bpm_events DISABLE TRIGGER bpm_events_captured_truncate_immutable")
    execute("TRUNCATE #{Enum.map_join(@tables, ", ", &"#{p}.#{&1}")}")
    execute("ALTER TABLE #{p}.bpm_events ENABLE TRIGGER bpm_events_captured_truncate_immutable")

    for table <- @tables do
      execute("DROP TRIGGER IF EXISTS #{table}_derive_memory_space_identity ON #{p}.#{table}")

      for column <- @partition_columns do
        # Dropping a column drops its FK, check constraints and any index that includes it.
        execute("ALTER TABLE #{p}.#{table} DROP COLUMN IF EXISTS #{column} CASCADE")
      end
    end

    execute("ALTER TABLE #{p}.skill_hosts DROP COLUMN IF EXISTS memory_scope")
  end

  def down do
    raise Ecto.MigrationError, "dropping memory partition columns is irreversible"
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
