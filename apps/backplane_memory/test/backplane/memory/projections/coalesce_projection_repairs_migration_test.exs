defmodule Backplane.Memory.CoalesceProjectionRepairsMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Projections.CoalesceProjectionRepairsMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_905_000_008
  @migration_module Backplane.Repo.Migrations.CoalesceProjectionRepairs

  test "creates durable generation frontiers and deduplicates only unfinished legacy jobs" do
    prefix = "projection_repair_frontier_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      {event_a, event_b} = create_fixture(migration_repo, prefix)
      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [["host-a", "session-a", 0, 0, 0]] =
               migration_repo.query!("""
               SELECT host_id, session_id, requested_generation, inflight_generation,
                      completed_generation
               FROM "#{prefix}".bpm_projection_repair_frontiers
               """).rows

      assert [
               [
                 1,
                 "available",
                 %{
                   "event_id" => ^event_a,
                   "host_id" => "host-a",
                   "session_id" => "session-a"
                 }
               ],
               [3, "completed", %{"event_id" => ^event_b}]
             ] =
               migration_repo.query!("""
               SELECT id, state, args
               FROM "#{prefix}".oban_jobs
               WHERE worker = 'Backplane.Memory.Workers.ProjectionRepairWorker'
               ORDER BY state, id
               """).rows

      assert :ok =
               Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [[false]] =
               migration_repo.query!(
                 "SELECT to_regclass($1) IS NOT NULL",
                 ["#{prefix}.bpm_projection_repair_frontiers"]
               ).rows
    end)
  end

  defp create_fixture(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_events (
      id uuid PRIMARY KEY,
      host_id text,
      session_id text,
      schema_version integer
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".oban_jobs (
      id bigint PRIMARY KEY,
      worker text NOT NULL,
      state text NOT NULL,
      args jsonb NOT NULL
    )
    """)

    event_a = Ecto.UUID.generate()
    event_b = Ecto.UUID.generate()

    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_events (id, host_id, session_id, schema_version)
      VALUES ($1, 'host-a', 'session-a', 2), ($2, 'host-a', 'session-a', 2)
      """,
      [Ecto.UUID.dump!(event_a), Ecto.UUID.dump!(event_b)]
    )

    repo.query!(
      """
      INSERT INTO "#{prefix}".oban_jobs (id, worker, state, args)
      VALUES
        (1, 'Backplane.Memory.Workers.ProjectionRepairWorker', 'available', jsonb_build_object('event_id', $1::text)),
        (2, 'Backplane.Memory.Workers.ProjectionRepairWorker', 'retryable', jsonb_build_object('event_id', $2::text)),
        (3, 'Backplane.Memory.Workers.ProjectionRepairWorker', 'completed', jsonb_build_object('event_id', $2::text))
      """,
      [event_a, event_b]
    )

    {event_a, event_b}
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260905000008_coalesce_projection_repairs.exs")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.CoalesceProjectionRepairsMigrationTestRepo, config})

    Backplane.Memory.CoalesceProjectionRepairsMigrationTestRepo
  end

  defp with_isolated_schema(repo, prefix, fun) do
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end
