defmodule Backplane.Memory.Recall.TraceMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Recall.TraceMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_011
  @migration Backplane.Repo.Migrations.CreateMemoryRecallTraces

  test "00011 is prefix-aware, partition-enforced, constrained, cascading, and reversible across up/down/up" do
    prefix = "recall_trace_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_schema(migration_repo, prefix, fn ->
      load_migration()
      assert :ok = migrate(migration_repo, prefix, :up)

      assert Enum.sort(table_names(migration_repo, prefix)) ==
               ~w(memory_recall_candidates memory_recall_runs)

      refute "query" in column_names(migration_repo, prefix, "memory_recall_runs")
      assert "normalized_query" in column_names(migration_repo, prefix, "memory_recall_runs")
      assert "terminal_digest" in column_names(migration_repo, prefix, "memory_recall_runs")

      run_id = Ecto.UUID.generate()
      candidate_id = Ecto.UUID.generate()

      insert_run(migration_repo, prefix, run_id, "host-a", "request-a")
      insert_candidate(migration_repo, prefix, run_id, candidate_id, "host-a")

      assert_raise Postgrex.Error, fn ->
        insert_candidate(migration_repo, prefix, run_id, Ecto.UUID.generate(), "host-b")
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          """
          UPDATE "#{prefix}".memory_recall_runs SET tokens_used = token_budget + 1
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(run_id)]
        )
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!("""
        UPDATE "#{prefix}".memory_recall_candidates SET candidate_kind = 'unknown'
        WHERE id = (SELECT id FROM "#{prefix}".memory_recall_candidates LIMIT 1)
        """)
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!("""
        UPDATE "#{prefix}".memory_recall_candidates
        SET selected = true, rejection_reason = 'diversity'
        WHERE id = (SELECT id FROM "#{prefix}".memory_recall_candidates LIMIT 1)
        """)
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!("""
        UPDATE "#{prefix}".memory_recall_candidates
        SET rejection_reason = NULL
        WHERE id = (SELECT id FROM "#{prefix}".memory_recall_candidates LIMIT 1)
        """)
      end

      migration_repo.query!(
        ~s|DELETE FROM "#{prefix}".memory_recall_runs WHERE id = $1|,
        [Ecto.UUID.dump!(run_id)]
      )

      assert [[0]] ==
               migration_repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".memory_recall_candidates|
               ).rows

      assert :ok = migrate(migration_repo, prefix, :down)
      assert table_names(migration_repo, prefix) == []
      assert :ok = migrate(migration_repo, prefix, :up)

      assert Enum.sort(table_names(migration_repo, prefix)) ==
               ~w(memory_recall_candidates memory_recall_runs)
    end)
  end

  defp insert_run(repo, prefix, id, host_id, request_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_recall_runs
        (id, host_id, client_id, scope, namespace, request_id, correlation_id,
         query_hash, query_plan, filters, channel_weights, channel_availability,
         channel_errors, token_budget, tokens_used, result_count, status,
         expires_at, inserted_at, updated_at)
      VALUES ($1, $2, 'client-a', 'team', 'private', $3, 'correlation-a',
              decode(repeat('ab', 32), 'hex'), '{}', '{}', '{}', '{}', '{}',
              100, 0, 0, 'running', now() + interval '30 days', now(), now())
      """,
      [Ecto.UUID.dump!(id), host_id, request_id]
    )
  end

  defp insert_candidate(repo, prefix, run_id, candidate_id, host_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_recall_candidates
        (id, recall_run_id, host_id, client_id, scope, namespace, candidate_id,
         candidate_kind, memory_type, source_ids, channel_scores, selected,
         rejection_reason, token_estimate, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, 'client-a', 'team', 'private', $3,
              'memory', 'semantic', ARRAY[$3]::uuid[], '{}', false, 'review', 4, now(), now())
      """,
      [Ecto.UUID.dump!(run_id), host_id, Ecto.UUID.dump!(candidate_id)]
    )
  end

  defp table_names(repo, prefix) do
    repo.query!(
      """
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = $1 AND table_name IN ('memory_recall_runs', 'memory_recall_candidates')
      ORDER BY table_name
      """,
      [prefix]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp column_names(repo, prefix, table) do
    repo.query!(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 ORDER BY ordinal_position
      """,
      [prefix, table]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp migrate(repo, prefix, :up),
    do: Ecto.Migrator.up(repo, @version, @migration, prefix: prefix, log: false)

  defp migrate(repo, prefix, :down),
    do: Ecto.Migrator.down(repo, @version, @migration, prefix: prefix, log: false)

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260812000011_create_memory_recall_traces.exs")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.Recall.TraceMigrationTestRepo, config})
    Backplane.Memory.Recall.TraceMigrationTestRepo
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
