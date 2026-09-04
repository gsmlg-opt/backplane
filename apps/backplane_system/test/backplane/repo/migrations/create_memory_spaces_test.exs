defmodule Backplane.Repo.Migrations.CreateMemorySpaceRegistryTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.MemorySpaces
  alias Backplane.Repo
  alias Backplane.Repo.Migrations.CreateMemorySpaceRegistry, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260905000001_create_memory_space_registry.exs",
                    __DIR__
                  )
  @migration_version 20_260_905_000_001

  setup do
    Code.require_file(@migration_path)

    prefix = "memory_spaces_#{System.unique_integer([:positive])}"
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    Repo.query!("""
    CREATE TABLE "#{prefix}".skill_hosts (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      memory_scope text NOT NULL,
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL
    )
    """)

    on_exit(fn -> Repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)
    %{prefix: prefix}
  end

  test "backfills every existing host and remains idempotent", %{prefix: prefix} do
    first_host_id = insert_host(prefix, "first", "scope:first")
    second_host_id = insert_host(prefix, "second", "scope:second")

    run_migration(prefix)

    expected_rows =
      [
        {first_host_id, "scope:first", MemorySpaces.private_host_space_id(first_host_id)},
        {second_host_id, "scope:second", MemorySpaces.private_host_space_id(second_host_id)}
      ]
      |> Enum.sort()

    assert registry_rows(prefix) == expected_rows

    first_rows = counts(prefix)
    apply(Migration, :provision_existing_hosts, [Repo, prefix])
    apply(Migration, :provision_existing_hosts, [Repo, prefix])

    assert counts(prefix) == first_rows
    assert registry_rows(prefix) == expected_rows
  end

  test "database constraints reject invalid enum and blank partition values", %{prefix: prefix} do
    run_migration(prefix)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            ~s|INSERT INTO "#{prefix}".bpm_memory_spaces (id, kind, status, inserted_at, updated_at) VALUES (gen_random_uuid(), 'public', 'active', now(), now())|
          )
        end,
        mode: :savepoint
      )
    end

    host_id = insert_host(prefix, "constraint-host", "scope")
    apply(Migration, :provision_existing_hosts, [Repo, prefix])

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            ~s|UPDATE "#{prefix}".bpm_memory_space_entitlements SET scope = ' ' WHERE host_id = $1|,
            [Ecto.UUID.dump!(host_id)]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            ~s|INSERT INTO "#{prefix}".bpm_memory_space_backfill_issues (id, source_table, source_id, reason, disposition, details, inserted_at, updated_at) VALUES (gen_random_uuid(), 'facts', gen_random_uuid()::text, 'ambiguous', 'ignored', '{}'::jsonb, now(), now())|
          )
        end,
        mode: :savepoint
      )
    end
  end

  defp run_migration(prefix) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      Migration,
      :forward,
      :up,
      :up,
      log: false,
      prefix: prefix
    )
  end

  defp insert_host(prefix, name, scope) do
    id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{prefix}".skill_hosts (id, name, memory_scope, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())|,
      [Ecto.UUID.dump!(id), name, scope]
    )

    id
  end

  defp counts(prefix) do
    for table <- [
          "bpm_memory_spaces",
          "bpm_memory_space_entitlements",
          "bpm_memory_space_legacy_aliases"
        ] do
      %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{prefix}"."#{table}"|)
      {table, count}
    end
  end

  defp registry_rows(prefix) do
    %{rows: rows} =
      Repo.query!("""
      SELECT entitlement.host_id::text, entitlement.scope, space.id::text
      FROM "#{prefix}".bpm_memory_space_entitlements AS entitlement
      JOIN "#{prefix}".bpm_memory_spaces AS space ON space.id = entitlement.memory_space_id
      ORDER BY entitlement.scope
      """)

    rows
    |> Enum.map(fn [host_id, scope, space_id] -> {host_id, scope, space_id} end)
    |> Enum.sort()
  end
end
