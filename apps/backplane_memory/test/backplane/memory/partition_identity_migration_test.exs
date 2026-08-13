defmodule Backplane.Memory.PartitionIdentityMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.PartitionIdentityMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_811_000_001
  @migration_module Backplane.Repo.Migrations.BackfillCanonicalMemoryPartitionIdentity

  test "backfills only host-proven captured events, streams, and host-sync memories" do
    prefix = "partition_identity_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_fixture_tables(migration_repo, prefix)

      host_id = Ecto.UUID.generate()
      missing_host_id = Ecto.UUID.generate()
      token_id = Ecto.UUID.generate()
      host_partition = "host:#{host_id}"

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".skill_hosts (id) VALUES ($1)|,
        [Ecto.UUID.dump!(host_id)]
      )

      insert_stream(migration_repo, prefix, "trusted-stream", host_id, "legacy-token")
      insert_stream(migration_repo, prefix, "untrusted-stream", host_id, "legacy-token")

      insert_stream(
        migration_repo,
        prefix,
        "missing-host-stream",
        missing_host_id,
        "legacy-token"
      )

      insert_event(migration_repo, prefix, "trusted-stream", host_id, token_id, "legacy-token")
      insert_event(migration_repo, prefix, "untrusted-stream", host_id, nil, "legacy-token")

      insert_event(
        migration_repo,
        prefix,
        "missing-host-stream",
        missing_host_id,
        token_id,
        "legacy-token"
      )

      trusted_memory_id = insert_memory(migration_repo, prefix, host_id, "public", "legacy-token")
      direct_memory_id = insert_memory(migration_repo, prefix, host_id, "shared", "legacy-token")

      missing_host_memory_id =
        insert_memory(migration_repo, prefix, missing_host_id, "public", "legacy-token")

      insert_request(migration_repo, prefix, trusted_memory_id, "host-memory.v1:#{host_id}")
      insert_request(migration_repo, prefix, direct_memory_id, "direct:host:#{host_id}")

      insert_request(
        migration_repo,
        prefix,
        missing_host_memory_id,
        "host-memory.v1:#{missing_host_id}"
      )

      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert [["legacy-token"], [host_partition], ["legacy-token"]] ==
               migration_repo.query!("""
               SELECT client_id
               FROM "#{prefix}".bpm_events
               ORDER BY stream_id
               """).rows

      assert [["legacy-token"], [host_partition], ["legacy-token"]] ==
               migration_repo.query!("""
               SELECT client_id
               FROM "#{prefix}".bpm_streams
               ORDER BY stream_id
               """).rows

      memories =
        migration_repo.query!("""
        SELECT id::text, client_id, namespace
        FROM "#{prefix}".bpm_memories
        """).rows
        |> Map.new(fn [id, client_id, namespace] -> {id, {client_id, namespace}} end)

      assert memories[trusted_memory_id] == {host_partition, "private"}
      assert memories[direct_memory_id] == {"legacy-token", "shared"}
      assert memories[missing_host_memory_id] == {"legacy-token", "public"}

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          ~s|UPDATE "#{prefix}".bpm_events SET client_id = 'mutated' WHERE stream_id = 'trusted-stream'|
        )
      end
    end)
  end

  test "rejects rollback because legacy partition identities cannot be recovered" do
    prefix = "partition_identity_migration_down_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_fixture_tables(migration_repo, prefix)
      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      assert_raise Ecto.MigrationError,
                   ~r/irreversible.*legacy token\/client partition identities cannot be recovered/i,
                   fn ->
                     Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
                       prefix: prefix,
                       log: false
                     )
                   end
    end)
  end

  defp create_fixture_tables(repo, prefix) do
    repo.query!(~s|CREATE TABLE "#{prefix}".skill_hosts (id uuid PRIMARY KEY)|)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_streams (
      stream_id text PRIMARY KEY,
      host_id text,
      client_id text
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_events (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      stream_id text NOT NULL,
      schema_version integer,
      host_id text,
      client_id text,
      ingest_auth_token_id uuid
    )
    """)

    repo.query!("""
    CREATE FUNCTION "#{prefix}".reject_captured_event_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.schema_version IS NOT NULL THEN
        RAISE EXCEPTION 'captured memory events are immutable'
          USING ERRCODE = '55000';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    repo.query!("""
    CREATE TRIGGER bpm_events_captured_immutable
    BEFORE UPDATE OR DELETE ON "#{prefix}".bpm_events
    FOR EACH ROW
    EXECUTE FUNCTION "#{prefix}".reject_captured_event_mutation()
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memories (
      id uuid PRIMARY KEY,
      host_id text NOT NULL,
      client_id text,
      namespace text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_remember_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      idempotency_scope text NOT NULL,
      memory_id uuid NOT NULL
    )
    """)
  end

  defp insert_stream(repo, prefix, stream_id, host_id, client_id) do
    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_streams (stream_id, host_id, client_id) VALUES ($1, $2, $3)|,
      [stream_id, host_id, client_id]
    )
  end

  defp insert_event(repo, prefix, stream_id, host_id, token_id, client_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_events
        (stream_id, schema_version, host_id, client_id, ingest_auth_token_id)
      VALUES ($1, 1, $2, $3, $4)
      """,
      [stream_id, host_id, client_id, dump_uuid(token_id)]
    )
  end

  defp insert_memory(repo, prefix, host_id, namespace, client_id) do
    id = Ecto.UUID.generate()

    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memories (id, host_id, client_id, namespace)
      VALUES ($1, $2, $3, $4)
      """,
      [Ecto.UUID.dump!(id), host_id, client_id, namespace]
    )

    id
  end

  defp insert_request(repo, prefix, memory_id, scope) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memory_remember_requests (idempotency_scope, memory_id)
      VALUES ($1, $2)
      """,
      [scope, Ecto.UUID.dump!(memory_id)]
    )
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260811000001_backfill_canonical_memory_partition_identity.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.PartitionIdentityMigrationTestRepo, config})
    Backplane.Memory.PartitionIdentityMigrationTestRepo
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
