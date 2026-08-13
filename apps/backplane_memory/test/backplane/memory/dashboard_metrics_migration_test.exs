defmodule Backplane.Memory.DashboardMetricsMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.DashboardMetricsMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_019
  @migration Backplane.Repo.Migrations.IndexMemoryDashboardRecallWindow

  test "00019 adds a prefix-safe global recall-window index and reverses cleanly" do
    prefix = "dashboard_metrics_#{Ecto.UUID.generate() |> String.replace("-", "_")}"
    migration_repo = start_migration_repo()
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      migration_repo.query!("""
      CREATE TABLE "#{prefix}".memory_recall_runs (
        id uuid PRIMARY KEY,
        inserted_at timestamptz NOT NULL
      )
      """)

      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      assert ["memory_recall_runs_dashboard_window_idx"] == index_names(migration_repo, prefix)

      assert :ok =
               Ecto.Migrator.down(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      assert [] == index_names(migration_repo, prefix)
    after
      migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end

  defp index_names(repo, prefix) do
    repo.query!(
      """
      SELECT indexname
      FROM pg_indexes
      WHERE schemaname = $1 AND tablename = 'memory_recall_runs'
        AND indexname = 'memory_recall_runs_dashboard_window_idx'
      ORDER BY indexname
      """,
      [prefix]
    ).rows
    |> List.flatten()
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000019_index_memory_dashboard_recall_window.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.DashboardMetricsMigrationTestRepo, config})
    Backplane.Memory.DashboardMetricsMigrationTestRepo
  end
end
