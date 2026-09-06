defmodule Backplane.Memory.EdgeSync.MigrationRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.EdgeSync.MigrationTest do
  use ExUnit.Case, async: false
  alias Backplane.Memory.EdgeSync.MigrationRepo, as: Repo

  test "installs all durable tables and rolls back cleanly" do
    config = Application.fetch_env!(:backplane_memory, :repo).config() |> Keyword.delete(:pool)
    start_supervised!({Repo, config})
    prefix = "edge_migration_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{prefix}"))

    on_exit(fn ->
      {:ok, pid} = Repo.start_link(config)
      Repo.query!(~s(DROP SCHEMA "#{prefix}" CASCADE))
      GenServer.stop(pid)
    end)

    Repo.query!(~s|CREATE TABLE "#{prefix}".bpm_memory_spaces (id uuid PRIMARY KEY)|)

    Repo.query!(
      ~s|CREATE TABLE "#{prefix}".bpm_memory_space_entitlements (memory_space_id uuid, scope text, namespace text)|
    )

    Repo.query!(
      ~s|CREATE TABLE "#{prefix}".bpm_memories (memory_space_id uuid, scope text, namespace text)|
    )

    space = Ecto.UUID.dump!(Ecto.UUID.generate())
    Repo.query!(~s|INSERT INTO "#{prefix}".bpm_memory_spaces VALUES ($1)|, [space])

    Repo.query!(~s|INSERT INTO "#{prefix}".bpm_memories VALUES ($1,'legacy','team:exact')|, [
      space
    ])

    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000004_create_host_memory_edge_sync.exs"
      )

    assert File.exists?(path)
    Code.require_file(path)

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               20_260_905_000_004,
               Backplane.Repo.Migrations.CreateHostMemoryEdgeSync,
               prefix: prefix,
               log: false
             )

    for table <-
          ~w(bpm_memory_partition_revisions bpm_memory_changes bpm_host_memory_cursors bpm_host_memory_deliveries bpm_memory_snapshots bpm_memory_snapshot_chunks bpm_host_memory_compat_receipts) do
      assert [[true]] =
               Repo.query!("SELECT to_regclass($1) IS NOT NULL", [prefix <> "." <> table]).rows
    end

    assert [[0, 1, "team:exact"]] =
             Repo.query!(
               ~s|SELECT current_revision,first_available_revision,namespace FROM "#{prefix}".bpm_memory_partition_revisions|
             ).rows

    assert [[0]] = Repo.query!(~s|SELECT count(*) FROM "#{prefix}".bpm_memory_changes|).rows

    for {module, keys} <- [
          {Backplane.Memory.EdgeSync.PartitionRevision, [:memory_space_id, :scope, :namespace]},
          {Backplane.Memory.EdgeSync.Change, [:memory_space_id, :scope, :namespace, :revision]},
          {Backplane.Memory.EdgeSync.Cursor, [:host_id, :memory_space_id, :scope, :namespace]},
          {Backplane.Memory.EdgeSync.Delivery, [:id]},
          {Backplane.Memory.EdgeSync.Snapshot, [:id]},
          {Backplane.Memory.EdgeSync.SnapshotChunk, [:snapshot_id, :chunk_index]},
          {Backplane.Memory.EdgeSync.CompatReceipt, [:id]}
        ] do
      assert module.__schema__(:primary_key) == keys
    end

    assert :ok =
             Ecto.Migrator.down(
               Repo,
               20_260_905_000_004,
               Backplane.Repo.Migrations.CreateHostMemoryEdgeSync,
               prefix: prefix,
               log: false
             )
  end
end
