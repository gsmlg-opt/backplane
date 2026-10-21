defmodule Backplane.Repo.Migrations.AddMemoryHostAccessTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo.Migrations.{AddMemoryHostAccess, CreateMemorySpaceRegistry}

  setup do
    for file <- [
          "20260905000001_create_memory_space_registry.exs",
          "20261020000004_add_memory_host_access.exs"
        ] do
      Code.require_file(Path.expand("../../../../priv/repo/migrations/" <> file, __DIR__))
    end

    prefix = "memory_access_#{System.unique_integer([:positive])}"
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    Repo.query!(
      ~s|CREATE TABLE "#{prefix}".skill_hosts (id uuid PRIMARY KEY, name text NOT NULL, memory_scope text NOT NULL, inserted_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL)|
    )

    host = Ecto.UUID.generate()
    recipient = Ecto.UUID.generate()

    for id <- [host, recipient] do
      Repo.query!(
        ~s|INSERT INTO "#{prefix}".skill_hosts VALUES ($1, $2, 'private-scope', now(), now())|,
        [Ecto.UUID.dump!(id), id]
      )
    end

    run_migration(prefix, CreateMemorySpaceRegistry, 20_260_905_000_001)
    on_exit(fn -> Repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)
    %{prefix: prefix, host: host, recipient: recipient}
  end

  test "alias proof preserves private history, revoked status and defaults; foreign rows need disposition",
       c do
    Repo.query!(
      """
      INSERT INTO "#{c.prefix}".bpm_memory_space_entitlements
        (id, memory_space_id, host_id, scope, namespace, default_capture, status, inserted_at, updated_at)
      SELECT gen_random_uuid(), memory_space_id, host_id, 'historical', 'other-namespace', false, 'revoked', now(), now()
      FROM "#{c.prefix}".bpm_memory_space_entitlements WHERE host_id = $1
      """,
      [Ecto.UUID.dump!(c.host)]
    )

    %{rows: [[foreign_id]]} =
      Repo.query!(
        """
        INSERT INTO "#{c.prefix}".bpm_memory_space_entitlements
          (id, memory_space_id, host_id, scope, namespace, default_capture, status, inserted_at, updated_at)
        SELECT gen_random_uuid(), memory_space_id, $2, 'foreign', 'private', false, 'active', now(), now()
        FROM "#{c.prefix}".bpm_memory_space_entitlements WHERE host_id = $1 AND default_capture RETURNING id::text
        """,
        [Ecto.UUID.dump!(c.host), Ecto.UUID.dump!(c.recipient)]
      )

    before =
      Repo.query!(
        ~s|SELECT id, memory_space_id, host_id, scope, namespace, status, default_capture FROM "#{c.prefix}".bpm_memory_space_entitlements ORDER BY id|
      ).rows

    run_migration(c.prefix, AddMemoryHostAccess, 20_261_020_000_004)

    assert Repo.query!(
             ~s|SELECT id, memory_space_id, host_id, scope, namespace, status, default_capture FROM "#{c.prefix}".bpm_memory_space_entitlements ORDER BY id|
           ).rows == before

    assert %{rows: [[3]]} =
             Repo.query!(
               ~s|SELECT count(*) FROM "#{c.prefix}".bpm_memory_space_entitlements WHERE capabilities = ARRAY['deliver','forget','read','remember']::text[] AND authority_version = 1 AND offline_read_lease_seconds = 0|
             )

    assert %{rows: [[[], "active"]]} =
             Repo.query!(
               ~s|SELECT capabilities, status FROM "#{c.prefix}".bpm_memory_space_entitlements WHERE id = $1|,
               [Ecto.UUID.dump!(foreign_id)]
             )

    assert %{rows: [["shared_access_requires_disposition", "pending", details]]} =
             Repo.query!(
               ~s|SELECT reason, disposition, details FROM "#{c.prefix}".bpm_memory_space_backfill_issues WHERE source_id = $1|,
               [foreign_id]
             )

    assert Enum.sort(Map.keys(details)) == ~w(host_id memory_space_id namespace scope)
    assert details["host_id"] == c.recipient
  end

  test "database enforces capability, version and lease invariants", c do
    run_migration(c.prefix, AddMemoryHostAccess, 20_261_020_000_004)

    for assignment <- [
          "capabilities = ARRAY['deliver']::text[]",
          "capabilities = ARRAY['read','read']::text[]",
          "capabilities = ARRAY['unknown']::text[]",
          "capabilities = ARRAY['read','deliver']::text[]",
          "capabilities = ARRAY[NULL]::text[]",
          "authority_version = 0",
          "offline_read_lease_seconds = 301",
          "capabilities = ARRAY['remember']::text[], offline_read_lease_seconds = 1"
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.query!(~s|UPDATE "#{c.prefix}".bpm_memory_space_entitlements SET #{assignment}|)
          end,
          mode: :savepoint
        )
      end
    end
  end

  test "authority audits are append-only and migration is forward-only", c do
    run_migration(c.prefix, AddMemoryHostAccess, 20_261_020_000_004)

    Repo.query!("""
    INSERT INTO "#{c.prefix}".bpm_memory_access_audits
      (id, request_id, actor_kind, action, access_id, host_id, memory_space_id, scope, namespace,
       new_status, new_capabilities, new_offline_read_lease_seconds, new_authority_version, reason, inserted_at)
    SELECT gen_random_uuid(), gen_random_uuid(), 'system', 'grant', id, host_id, memory_space_id,
      scope, namespace, status, capabilities, 0, 1, 'test migration', now()
    FROM "#{c.prefix}".bpm_memory_space_entitlements
    """)

    for sql <- [
          ~s|UPDATE "#{c.prefix}".bpm_memory_access_audits SET reason = 'changed'|,
          ~s|DELETE FROM "#{c.prefix}".bpm_memory_access_audits|
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> Repo.query!(sql) end, mode: :savepoint)
      end
    end

    refute function_exported?(AddMemoryHostAccess, :down, 0)
  end

  defp run_migration(prefix, module, version) do
    Ecto.Migration.Runner.run(Repo, Repo.config(), version, module, :forward, :up, :up,
      log: false,
      prefix: prefix
    )
  end
end
