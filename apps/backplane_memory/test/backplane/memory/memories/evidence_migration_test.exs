defmodule Backplane.Memory.Memories.EvidenceMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Memories.EvidenceMigrationTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories

  @migration_version 20_260_806_000_002
  @migration_module Backplane.Repo.Migrations.ReplaceMemoryExactCandidateIndex

  test "remember requests and evidence expose the durable constraints and indexes" do
    assert [["session_id", "text", "YES"]] =
             repo().query!("""
             SELECT column_name, data_type, is_nullable
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'bpm_memory_evidence'
               AND column_name = 'session_id'
             """).rows

    objects =
      repo().query!("""
      SELECT relname
      FROM pg_class
      WHERE relnamespace = current_schema()::regnamespace
        AND relname IN (
          'bpm_memory_remember_requests',
          'bpm_memory_evidence',
          'bpm_memory_remember_requests_scope_key_uniq',
          'bpm_memory_evidence_memory_created_id_idx',
          'bpm_memories_exact_candidate_host_uniq'
        )
      ORDER BY relname
      """).rows

    assert Enum.map(objects, &hd/1) ==
             Enum.sort([
               "bpm_memories_exact_candidate_host_uniq",
               "bpm_memory_evidence",
               "bpm_memory_evidence_memory_created_id_idx",
               "bpm_memory_remember_requests",
               "bpm_memory_remember_requests_scope_key_uniq"
             ])

    constraints =
      repo().query!("""
      SELECT conname
      FROM pg_constraint
      WHERE connamespace = current_schema()::regnamespace
        AND conname IN (
          'bpm_memory_remember_requests_scope_nonempty',
          'bpm_memory_remember_requests_key_nonempty',
          'bpm_memory_remember_requests_hash_length',
          'bpm_memory_evidence_kind_check',
          'bpm_memory_evidence_score_check',
          'bpm_memory_evidence_source_check'
        )
      ORDER BY conname
      """).rows

    assert Enum.map(constraints, &hd/1) ==
             Enum.sort([
               "bpm_memory_evidence_kind_check",
               "bpm_memory_evidence_score_check",
               "bpm_memory_evidence_source_check",
               "bpm_memory_remember_requests_hash_length",
               "bpm_memory_remember_requests_key_nonempty",
               "bpm_memory_remember_requests_scope_nonempty"
             ])
  end

  test "database rejects invalid request and evidence provenance" do
    {:ok, memory} = Memories.remember("migration provenance", agent_id: "agent", host_id: "host")

    assert_sql_error(:check_violation, fn ->
      insert_request(memory.id, "", "key", :crypto.strong_rand_bytes(32))
    end)

    assert_sql_error(:check_violation, fn ->
      insert_request(memory.id, "direct", "key", <<1>>)
    end)

    request_id = Ecto.UUID.generate()

    repo().query!(
      """
      INSERT INTO bpm_memory_remember_requests
        (id, idempotency_scope, idempotency_key, request_hash, memory_id, inserted_at, updated_at)
      VALUES ($1, 'direct', 'valid', $2, $3, now(), now())
      """,
      [Ecto.UUID.dump!(request_id), :crypto.strong_rand_bytes(32), Ecto.UUID.dump!(memory.id)]
    )

    assert_sql_error(:check_violation, fn ->
      insert_evidence(memory.id, request_id, "unknown", 1.0)
    end)

    assert_sql_error(:check_violation, fn ->
      insert_evidence(memory.id, request_id, "supports", 1.1)
    end)

    assert_sql_error(:check_violation, fn ->
      repo().query!(
        """
        INSERT INTO bpm_memory_evidence
          (memory_id, source_request_id, source_session_id, host_id,
           evidence_kind, support_score, created_at)
        VALUES ($1, $2, 'session', 'host', 'supports', 1.0, now())
        """,
        [Ecto.UUID.dump!(memory.id), Ecto.UUID.dump!(request_id)]
      )
    end)
  end

  test "request and evidence rows reject update, delete, and truncate" do
    {:ok, memory} =
      Memories.remember("immutable provenance",
        agent_id: "agent",
        host_id: "host",
        idempotency_scope: "direct",
        idempotency_key: "immutable"
      )

    for table <- ["bpm_memory_remember_requests", "bpm_memory_evidence"],
        statement <- [
          "UPDATE #{table} SET memory_id = memory_id WHERE memory_id = '#{memory.id}'",
          "DELETE FROM #{table} WHERE memory_id = '#{memory.id}'"
        ] do
      assert_sql_error(:object_not_in_prerequisite_state, fn -> repo().query!(statement) end)
    end

    evidence_truncate_error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn -> repo().query!("TRUNCATE bpm_memory_evidence") end)
      end

    assert evidence_truncate_error.postgres.code in [
             :object_not_in_prerequisite_state,
             :feature_not_supported,
             :object_in_use
           ]

    request_truncate_error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn -> repo().query!("TRUNCATE bpm_memory_remember_requests") end)
      end

    assert request_truncate_error.postgres.code in [
             :object_not_in_prerequisite_state,
             :feature_not_supported,
             :object_in_use
           ]
  end

  test "exact candidate index includes every partition and replaces the old index" do
    assert [[definition]] =
             repo().query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = current_schema()
               AND indexname = 'bpm_memories_exact_candidate_host_uniq'
             """).rows

    for fragment <- [
          "content_hash",
          "host_id",
          "scope",
          "namespace",
          "memory_type",
          "metadata",
          "project",
          "client_id"
        ] do
      assert definition =~ fragment
    end

    assert definition =~ "jsonb_typeof"

    assert [] ==
             repo().query!("""
             SELECT 1 FROM pg_indexes
             WHERE schemaname = current_schema() AND indexname = 'bpm_memories_dedup_uniq'
             """).rows
  end

  test "concurrent index replacement creates the successor before dropping its predecessor" do
    source =
      :backplane_system
      |> Application.app_dir(
        "priv/repo/migrations/20260806000002_replace_memory_exact_candidate_index.exs"
      )
      |> File.read!()

    up = source |> String.split("def down do") |> hd()
    down = source |> String.split("def down do") |> List.last()

    assert index_of(up, "CREATE UNIQUE INDEX CONCURRENTLY bpm_memories_exact_candidate_uniq") <
             index_of(
               up,
               "DROP INDEX CONCURRENTLY IF EXISTS \#{qualified(\"bpm_memories_dedup_uniq\")}"
             )

    assert index_of(down, "down_collision_preflight_sql") <
             index_of(down, "CREATE UNIQUE INDEX CONCURRENTLY bpm_memories_dedup_uniq")

    assert index_of(down, "CREATE UNIQUE INDEX CONCURRENTLY bpm_memories_dedup_uniq") <
             index_of(
               down,
               "DROP INDEX CONCURRENTLY IF EXISTS \#{qualified(\"bpm_memories_exact_candidate_uniq\")}"
             )
  end

  test "down preflight refuses active legacy-key collisions without changing the expanded index" do
    prefix = "memory_evidence_preflight_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_preflight_fixture(migration_repo, prefix)
      load_index_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      insert_preflight_collision(migration_repo, prefix, "collision:first")
      insert_preflight_collision(migration_repo, prefix, "collision:second")

      error =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
            prefix: prefix,
            log: false
          )
        end

      assert error.postgres.code == :unique_violation
      assert error.postgres.message =~ "active (content_hash, scope) collisions exist"
      assert error.postgres.hint =~ "soft-delete colliding active memories"

      assert [["bpm_memories_exact_candidate_uniq"]] =
               migration_repo.query!("""
               SELECT indexname
               FROM pg_indexes
               WHERE schemaname = '#{prefix}'
                 AND indexname = 'bpm_memories_exact_candidate_uniq'
               """).rows

      assert [] =
               migration_repo.query!("""
               SELECT indexname
               FROM pg_indexes
               WHERE schemaname = '#{prefix}'
                 AND indexname = 'bpm_memories_dedup_uniq'
               """).rows
    end)
  end

  test "one durable source cannot be counted twice under different evidence kinds" do
    {:ok, memory} =
      Memories.remember("unique source",
        agent_id: "agent",
        host_id: "host",
        idempotency_scope: "direct",
        idempotency_key: "unique-source"
      )

    [[request_id]] =
      repo().query!(
        "SELECT source_request_id FROM bpm_memory_evidence WHERE memory_id = $1",
        [Ecto.UUID.dump!(memory.id)]
      ).rows

    assert_sql_error(:unique_violation, fn ->
      insert_evidence(memory.id, Ecto.UUID.load!(request_id), "contradicts", 0.0)
    end)
  end

  defp insert_request(memory_id, scope, key, hash) do
    repo().query!(
      """
      INSERT INTO bpm_memory_remember_requests
        (idempotency_scope, idempotency_key, request_hash, memory_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, now(), now())
      """,
      [scope, key, hash, Ecto.UUID.dump!(memory_id)]
    )
  end

  defp insert_evidence(memory_id, request_id, kind, score) do
    repo().query!(
      """
      INSERT INTO bpm_memory_evidence
        (memory_id, source_request_id, evidence_kind, support_score, created_at)
      VALUES ($1, $2, $3, $4, now())
      """,
      [Ecto.UUID.dump!(memory_id), Ecto.UUID.dump!(request_id), kind, score]
    )
  end

  defp assert_sql_error(code, fun) do
    error = assert_raise Postgrex.Error, fn -> repo().transaction(fun) end
    assert error.postgres.code == code
    error
  end

  defp index_of(source, needle) do
    {index, _length} = :binary.match(source, needle)
    index
  end

  defp create_preflight_fixture(migration_repo, prefix) do
    migration_repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memories (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      content_hash bytea NOT NULL,
      scope text NOT NULL,
      namespace text NOT NULL,
      memory_type text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      client_id text,
      deleted_at timestamptz
    )
    """)

    migration_repo.query!("""
    CREATE UNIQUE INDEX bpm_memories_dedup_uniq
    ON "#{prefix}".bpm_memories (content_hash, scope)
    WHERE deleted_at IS NULL
    """)
  end

  defp insert_preflight_collision(migration_repo, prefix, namespace) do
    migration_repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memories
        (content_hash, scope, namespace, memory_type, metadata, client_id)
      VALUES (decode('aa', 'hex'), 'private', $1, 'semantic', '{}', 'client')
      """,
      [namespace]
    )
  end

  defp load_index_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260806000002_replace_memory_exact_candidate_index.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.Memories.EvidenceMigrationTestRepo, config})
    Backplane.Memory.Memories.EvidenceMigrationTestRepo
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
