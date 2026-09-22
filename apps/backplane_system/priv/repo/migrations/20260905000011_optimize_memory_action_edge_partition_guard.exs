defmodule Backplane.Repo.Migrations.OptimizeMemoryActionEdgePartitionGuard do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")
    edges = "#{p}.memory_action_edges"
    actions = "#{p}.memory_actions"
    function = "#{p}.bpm_assert_memory_action_edges_canonical_partition"

    # The former guard searched the entire child table for each changed row.
    # Resolve the two action primary keys directly instead.
    execute("DROP TRIGGER bpm_memory_space_child_partition_guard ON #{edges}")

    execute("""
    CREATE OR REPLACE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM #{actions} AS source
        JOIN #{actions} AS target ON target.id = NEW.target_id
        WHERE source.id = NEW.source_id
          AND source.memory_space_id IS NOT NULL
          AND nullif(btrim(source.scope), '') IS NOT NULL
          AND nullif(btrim(source.namespace), '') IS NOT NULL
          AND source.memory_space_id = target.memory_space_id
          AND source.scope = target.scope
          AND source.namespace = target.namespace
      ) THEN
        RAISE EXCEPTION 'child row in memory_action_edges crosses canonical memory partition'
          USING ERRCODE = '23514',
                CONSTRAINT = 'memory_action_edges_canonical_partition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER bpm_memory_space_child_partition_guard
    AFTER INSERT OR UPDATE ON #{edges}
    DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW
    EXECUTE FUNCTION #{function}()
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only migration: optimized action-edge partition guard cannot be discarded"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
