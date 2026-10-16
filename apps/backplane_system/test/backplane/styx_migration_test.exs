defmodule BackplaneSystem.StyxMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule BackplaneSystem.StyxMigrationTest do
  use ExUnit.Case, async: false

  @create_version 20_260_410_000_001
  @update_version 20_260_523_000_002
  @styx_version 20_261_016_000_001
  @create Backplane.Repo.Migrations.CreateObanTables
  @update Backplane.Repo.Migrations.UpdateObanToV14
  @styx Backplane.Repo.Migrations.MigrateObanToStyx

  setup do
    for file <- [
          "20260410000001_create_oban_tables.exs",
          "20260523000002_update_oban_to_v14.exs",
          "20261016000001_migrate_oban_to_styx.exs"
        ] do
      :backplane_system
      |> Application.app_dir("priv/repo/migrations/#{file}")
      |> Code.require_file()
    end

    config = Backplane.Repo.config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({BackplaneSystem.StyxMigrationTestRepo, config})
    repo = BackplaneSystem.StyxMigrationTestRepo
    prefix = "styx_migration_#{System.unique_integer([:positive])}"
    repo.query!(~s(CREATE SCHEMA "#{prefix}"))
    %{repo: repo, prefix: prefix}
  end

  test "fresh historical schema upgrades and rolls back without losing job data or sequence state",
       %{repo: repo, prefix: prefix} do
    try do
      assert :ok = migrate(repo, prefix, :up, @create_version, @create)
      assert :ok = migrate(repo, prefix, :up, @update_version, @update)

      repo.query!("""
      INSERT INTO "#{prefix}".oban_jobs
        (state, queue, worker, args, meta, errors, tags, attempted_by, attempt, priority,
         attempted_at, cancelled_at, completed_at, discarded_at)
      SELECT state, 'memory', 'Backplane.Memory.Workers.ProjectionRepairWorker',
        jsonb_build_object('event_id', state::text), '{"preserved":true}',
        ARRAY['{"attempt":1,"error":"preserved"}'::jsonb], ARRAY['preserved'],
        ARRAY['node-a'], 1, 3, '2026-10-01 01:02:03.123456'::timestamp,
        '2026-10-01'::timestamp, '2026-10-02'::timestamp, '2026-10-03'::timestamp
      FROM unnest(enum_range(NULL::"#{prefix}".oban_job_state)) AS state
      """)

      repo.query!("""
      INSERT INTO "#{prefix}".oban_peers
      VALUES ('peer-a', 'node-a', '2026-10-01', '2026-10-02')
      """)

      repo.query!("""
      CREATE TABLE "#{prefix}".bpm_memory_space_backfill_issues (
        source_table text NOT NULL, source_id text NOT NULL,
        disposition text NOT NULL CHECK (disposition IN ('pending', 'resolved', 'approved_waiver')),
        resolved_at timestamp, details jsonb, PRIMARY KEY (source_table, source_id)
      )
      """)

      repo.query!("""
      INSERT INTO "#{prefix}".bpm_memory_space_backfill_issues VALUES
        ('oban_jobs', '1', 'approved_waiver', '2026-10-01', '{"reason":"approved"}'),
        ('memory_audit_log', '2', 'pending', NULL, '{}')
      """)

      jobs = rows(repo, prefix, "oban_jobs")
      peers = rows(repo, prefix, "oban_peers")
      sequence = sequence_value(repo, prefix, "oban")

      assert :ok = migrate(repo, prefix, :up, @styx_version, @styx)
      assert rows(repo, prefix, "styx_jobs") == jobs
      assert rows(repo, prefix, "styx_peers") == peers
      assert sequence_value(repo, prefix, "styx") == sequence
      assert Styx.Migration.migrated_version(repo: repo, prefix: prefix) == 1

      assert repo.all(Styx.Job, prefix: prefix) |> length() == length(jobs)

      assert [[nil, nil]] =
               repo.query!("SELECT to_regclass($1), to_regclass($2)", [
                 "#{prefix}.oban_jobs",
                 "#{prefix}.oban_peers"
               ]).rows

      assert [
               [
                 "styx_jobs",
                 "approved_waiver",
                 ~N[2026-10-01 00:00:00.000000],
                 %{"reason" => "approved"}
               ]
             ] =
               repo.query!("""
               SELECT source_table, disposition, resolved_at, details FROM "#{prefix}".bpm_memory_space_backfill_issues
               WHERE source_id = '1'
               """).rows

      assert [[1]] = repo.query!(~s|SELECT "#{prefix}".styx_wrap_id(2147483648)|).rows

      assert :ok = migrate(repo, prefix, :down, @styx_version, @styx)
      assert rows(repo, prefix, "oban_jobs") == jobs
      assert rows(repo, prefix, "oban_peers") == peers
      assert sequence_value(repo, prefix, "oban") == sequence

      assert [["14"]] =
               repo.query!("SELECT obj_description(to_regclass($1))", ["#{prefix}.oban_jobs"]).rows

      assert [
               [
                 "oban_jobs",
                 "approved_waiver",
                 ~N[2026-10-01 00:00:00.000000],
                 %{"reason" => "approved"}
               ]
             ] =
               repo.query!("""
               SELECT source_table, disposition, resolved_at, details FROM "#{prefix}".bpm_memory_space_backfill_issues
               WHERE source_id = '1'
               """).rows

      # Reapplying the conversion retains the same records and next generated ID.
      assert :ok = migrate(repo, prefix, :up, @styx_version, @styx)

      assert [[next_id]] =
               repo.query!("""
               INSERT INTO "#{prefix}".styx_jobs (worker) VALUES ('Worker') RETURNING id
               """).rows

      assert next_id == sequence + 1

      assert :ok = migrate(repo, prefix, :down, @styx_version, @styx)
      assert :ok = migrate(repo, prefix, :down, @update_version, @update)
      assert :ok = migrate(repo, prefix, :down, @create_version, @create)
      assert [[nil]] = repo.query!("SELECT to_regclass($1)", ["#{prefix}.oban_jobs"]).rows
    after
      repo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp migrate(repo, prefix, direction, version, module) do
    apply(Ecto.Migrator, direction, [repo, version, module, [prefix: prefix, log: false]])
  end

  defp rows(repo, prefix, table) do
    repo.query!(~s|SELECT to_jsonb(row) FROM "#{prefix}".#{table} AS row ORDER BY 1|).rows
  end

  defp sequence_value(repo, prefix, source) do
    [[value]] = repo.query!(~s(SELECT last_value FROM "#{prefix}".#{source}_jobs_id_seq)).rows
    value
  end
end
