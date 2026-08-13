defmodule Backplane.Memory.SemanticIdentityHostMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.SemanticIdentityHostMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_812_000_010
  @migration_module Backplane.Repo.Migrations.IncludeHostInMemoryExactCandidateIdentity

  test "00010 upgrades a prefixed identity index, permits cross-host rows, and guards down" do
    prefix = "memory_host_identity_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_fixture(migration_repo, prefix)
      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [[definition]] =
               migration_repo.query!("""
               SELECT indexdef
               FROM pg_indexes
               WHERE schemaname = '#{prefix}'
                 AND indexname = 'bpm_memories_exact_candidate_host_uniq'
               """).rows

      assert definition =~ "host_id"

      insert_memory(migration_repo, prefix, "host-a")
      insert_memory(migration_repo, prefix, "host-b")

      assert_raise Postgrex.Error, ~r/pre-host identity collisions exist/, fn ->
        Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
          prefix: prefix,
          log: false
        )
      end

      migration_repo.query!(~s|DELETE FROM "#{prefix}".bpm_memories WHERE host_id = 'host-b'|)

      assert :ok =
               Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [[old_definition]] =
               migration_repo.query!("""
               SELECT indexdef
               FROM pg_indexes
               WHERE schemaname = '#{prefix}'
                 AND indexname = 'bpm_memories_exact_candidate_uniq'
               """).rows

      refute old_definition =~ "(content_hash, host_id"
    end)
  end

  defp create_fixture(migration_repo, prefix) do
    migration_repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memories (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      content_hash bytea NOT NULL,
      host_id text NOT NULL,
      scope text NOT NULL,
      namespace text NOT NULL,
      memory_type text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      client_id text,
      deleted_at timestamptz
    )
    """)

    migration_repo.query!("""
    CREATE UNIQUE INDEX bpm_memories_exact_candidate_uniq
    ON "#{prefix}".bpm_memories (
      content_hash,
      scope,
      namespace,
      memory_type,
      (COALESCE(CASE WHEN jsonb_typeof(metadata->'project') = 'string' THEN metadata->>'project' ELSE '' END, '')),
      (COALESCE(client_id, ''))
    )
    WHERE deleted_at IS NULL
    """)
  end

  defp insert_memory(migration_repo, prefix, host_id) do
    migration_repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memories
        (content_hash, host_id, scope, namespace, memory_type, metadata, client_id)
      VALUES (decode('aa', 'hex'), $1, 'scope', 'private', 'semantic', '{}', 'shared-client')
      """,
      [host_id]
    )
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000010_include_host_in_memory_exact_candidate_identity.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.SemanticIdentityHostMigrationTestRepo, config})
    Backplane.Memory.SemanticIdentityHostMigrationTestRepo
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
