defmodule Backplane.Memory.ApplicationCountMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.ApplicationCountMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_812_000_009
  @migration_module Backplane.Repo.Migrations.AddMemoryApplicationCount

  test "00009 backfills existing memories and enforces a nonnegative application count" do
    prefix = "application_count_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      migration_repo.query!("""
      CREATE TABLE "#{prefix}".bpm_memories (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        content text NOT NULL
      )
      """)

      migration_repo.query!(~s|INSERT INTO "#{prefix}".bpm_memories (content) VALUES ('old')|)
      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [[0]] =
               migration_repo.query!(
                 ~s|SELECT application_count FROM "#{prefix}".bpm_memories WHERE content = 'old'|
               ).rows

      assert [["NO", "0"]] =
               migration_repo.query!("""
               SELECT is_nullable, column_default
               FROM information_schema.columns
               WHERE table_schema = '#{prefix}'
                 AND table_name = 'bpm_memories'
                 AND column_name = 'application_count'
               """).rows

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(~s|UPDATE "#{prefix}".bpm_memories SET application_count = -1|)
      end

      assert :ok =
               Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [] =
               migration_repo.query!("""
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = '#{prefix}'
                 AND table_name = 'bpm_memories'
                 AND column_name = 'application_count'
               """).rows
    end)
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260812000009_add_memory_application_count.exs")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.ApplicationCountMigrationTestRepo, config})
    Backplane.Memory.ApplicationCountMigrationTestRepo
  end

  defp with_isolated_schema(migration_repo, prefix, fun) do
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end
