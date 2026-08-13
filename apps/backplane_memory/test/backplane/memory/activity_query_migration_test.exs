defmodule Backplane.Memory.ActivityQueryMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.ActivityQueryMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_812_000_017
  @migration_module Backplane.Repo.Migrations.IndexExactPartitionMemoryActivity

  test "00017 adds and reverses exact-partition activity indexes" do
    prefix = "activity_query_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_schema(migration_repo, prefix, fn ->
      create_tables(migration_repo, prefix)
      load_migration()

      assert :ok = migrate(migration_repo, prefix, :up)

      assert index_names(migration_repo, prefix) == [
               "bpm_events_activity_exact_partition_idx",
               "memory_activity_contributions_exact_partition_idx",
               "memory_activity_daily_exact_partition_idx"
             ]

      assert :ok = migrate(migration_repo, prefix, :down)
      assert index_names(migration_repo, prefix) == []
    end)
  end

  defp create_tables(repo, prefix) do
    for table <- ["memory_activity_daily", "memory_activity_subject_contributions"] do
      repo.query!("""
      CREATE TABLE "#{prefix}"."#{table}" (
        subject_id text,
        date date NOT NULL,
        project text NOT NULL,
        agent_id text NOT NULL,
        host_id text NOT NULL,
        client_id text NOT NULL,
        scope text NOT NULL,
        namespace text NOT NULL,
        event_type text NOT NULL
      )
      """)
    end

    repo.query!("""
    CREATE TABLE "#{prefix}"."bpm_events" (
      id text NOT NULL,
      host_id text NOT NULL,
      client_id text NOT NULL,
      scope text NOT NULL,
      namespace text NOT NULL,
      occurred_at timestamp NOT NULL,
      schema_version bigint
    )
    """)
  end

  defp index_names(repo, prefix) do
    repo.query!(
      """
      SELECT indexname
      FROM pg_indexes
      WHERE schemaname = $1
        AND indexname IN (
          'bpm_events_activity_exact_partition_idx',
          'memory_activity_contributions_exact_partition_idx',
          'memory_activity_daily_exact_partition_idx'
        )
      ORDER BY indexname
      """,
      [prefix]
    ).rows
    |> List.flatten()
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000017_index_exact_partition_memory_activity.exs"
    )
    |> Code.require_file()
  end

  defp migrate(repo, prefix, :up) do
    Ecto.Migrator.up(repo, @migration_version, @migration_module, prefix: prefix, log: false)
  end

  defp migrate(repo, prefix, :down) do
    Ecto.Migrator.down(repo, @migration_version, @migration_module, prefix: prefix, log: false)
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.ActivityQueryMigrationTestRepo, config})
    Backplane.Memory.ActivityQueryMigrationTestRepo
  end

  defp with_schema(repo, prefix, fun) do
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end
