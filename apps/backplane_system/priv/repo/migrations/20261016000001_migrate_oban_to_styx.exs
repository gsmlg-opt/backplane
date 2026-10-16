defmodule Backplane.Repo.Migrations.MigrateObanToStyx do
  use Ecto.Migration

  def up do
    rename_storage("oban", "styx", 1)

    execute """
    CREATE FUNCTION #{quoted_prefix()}.styx_wrap_id(value bigint) RETURNS int AS $$
    BEGIN
      RETURN (value % 2147483647)::int;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE
    """
  end

  def down do
    execute "DROP FUNCTION #{quoted_prefix()}.styx_wrap_id(value bigint)"
    rename_storage("styx", "oban", 14)
  end

  defp rename_storage(from, to, version) do
    quoted = quoted_prefix()

    # Renaming keeps every job, identifier, sequence position, and peer row in
    # place. All historical backfills run before this migration against oban_jobs.
    execute "ALTER TABLE #{quoted}.#{from}_jobs RENAME TO #{to}_jobs"
    execute "ALTER TABLE #{quoted}.#{from}_peers RENAME TO #{to}_peers"
    execute "ALTER TYPE #{quoted}.#{from}_job_state RENAME TO #{to}_job_state"
    execute "ALTER SEQUENCE #{quoted}.#{from}_jobs_id_seq RENAME TO #{to}_jobs_id_seq"

    execute """
    DO $$
    DECLARE item record;
    BEGIN
      FOR item IN
        SELECT indexname FROM pg_indexes
        WHERE schemaname = '#{escaped_prefix()}'
          AND tablename IN ('#{to}_jobs', '#{to}_peers')
          AND starts_with(indexname, '#{from}_')
      LOOP
        EXECUTE format('ALTER INDEX %I.%I RENAME TO %I',
          '#{escaped_prefix()}', item.indexname,
          '#{to}_' || substr(item.indexname, #{String.length(from) + 2}));
      END LOOP;
    END $$
    """

    execute "COMMENT ON TABLE #{quoted}.#{to}_jobs IS '#{version}'"

    execute """
    UPDATE #{quoted}.bpm_memory_space_backfill_issues
    SET source_table = '#{to}_jobs'
    WHERE source_table = '#{from}_jobs'
    """
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
  defp escaped_prefix, do: String.replace(prefix() || "public", "'", "''")
end
