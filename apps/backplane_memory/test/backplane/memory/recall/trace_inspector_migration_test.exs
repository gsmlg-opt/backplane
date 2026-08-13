defmodule Backplane.Memory.Recall.TraceInspectorMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Recall.TraceInspectorMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @base_version 20_260_812_000_011
  @version 20_260_812_000_012
  @base_migration Backplane.Repo.Migrations.CreateMemoryRecallTraces
  @migration Backplane.Repo.Migrations.AddMemoryRecallInspectorTraceFields

  test "00012 adds constrained Inspector metadata and typed provenance reversibly" do
    prefix = "recall_inspector_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_schema(migration_repo, prefix, fn ->
      load_migrations()
      assert :ok = migrate(migration_repo, prefix, @base_version, @base_migration, :up)
      assert :ok = migrate(migration_repo, prefix, @version, @migration, :up)

      assert ~w(reranker_duration_ms reranker_error_class reranker_provider reranker_status) --
               column_names(migration_repo, prefix, "memory_recall_runs") == []

      assert ~w(post_reranker_rank pre_reranker_rank source_refs) --
               column_names(migration_repo, prefix, "memory_recall_candidates") == []

      run_id = insert_run(migration_repo, prefix)
      candidate_id = Ecto.UUID.generate()

      insert_candidate(migration_repo, prefix, run_id, candidate_id, [
        %{"type" => "event", "id" => candidate_id}
      ])

      assert_raise Postgrex.Error, fn ->
        insert_candidate(migration_repo, prefix, run_id, Ecto.UUID.generate(), [
          %{"type" => "unknown", "id" => Ecto.UUID.generate()}
        ])
      end

      for invalid_refs <- [
            [%{"id" => candidate_id}],
            [%{"type" => "event", "id" => candidate_id, "content" => "private"}],
            [%{"type" => "event", "id" => "not-a-uuid"}]
          ] do
        assert_raise Postgrex.Error, fn ->
          insert_candidate(
            migration_repo,
            prefix,
            run_id,
            Ecto.UUID.generate(),
            invalid_refs
          )
        end
      end

      null_type_candidate_id = Ecto.UUID.generate()

      assert_raise Postgrex.Error, fn ->
        insert_candidate(migration_repo, prefix, run_id, null_type_candidate_id, [
          %{"type" => nil, "id" => null_type_candidate_id}
        ])
      end

      assert_raise Postgrex.Error, fn ->
        insert_candidate(
          migration_repo,
          prefix,
          run_id,
          Ecto.UUID.generate(),
          [%{"type" => "event", "id" => Ecto.UUID.generate()}]
        )
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          ~s|UPDATE "#{prefix}".memory_recall_candidates SET pre_reranker_rank = 0|
        )
      end

      assert :ok = migrate(migration_repo, prefix, @version, @migration, :down)
      refute "source_refs" in column_names(migration_repo, prefix, "memory_recall_candidates")
      assert :ok = migrate(migration_repo, prefix, @version, @migration, :up)
    end)
  end

  defp insert_run(repo, prefix) do
    id = Ecto.UUID.generate()

    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_recall_runs
        (id, host_id, client_id, scope, namespace, request_id, correlation_id,
         query_hash, query_plan, filters, channel_weights, channel_availability,
         channel_errors, token_budget, tokens_used, result_count, status,
         expires_at, inserted_at, updated_at)
      VALUES ($1, 'host-a', 'client-a', 'team', 'private', 'request-a', 'correlation-a',
              decode(repeat('ab', 32), 'hex'), '{}', '{}', '{}', '{}', '{}',
              100, 0, 0, 'running', now() + interval '30 days', now(), now())
      """,
      [Ecto.UUID.dump!(id)]
    )

    id
  end

  defp insert_candidate(repo, prefix, run_id, candidate_id, source_refs) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_recall_candidates
        (id, recall_run_id, host_id, client_id, scope, namespace, candidate_id,
         candidate_kind, memory_type, source_ids, source_refs, channel_scores, selected,
         rejection_reason, token_estimate, pre_reranker_rank, post_reranker_rank,
         inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'host-a', 'client-a', 'team', 'private', $2,
              'memory', 'semantic', ARRAY[$2]::uuid[], $3, '{}', false,
              'review', 4, 1, 1, now(), now())
      """,
      [Ecto.UUID.dump!(run_id), Ecto.UUID.dump!(candidate_id), %{"refs" => source_refs}]
    )
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

  defp migrate(repo, prefix, version, migration, direction),
    do: apply(Ecto.Migrator, direction, [repo, version, migration, [prefix: prefix, log: false]])

  defp load_migrations do
    base = Application.app_dir(:backplane_system, "priv/repo/migrations")
    Code.require_file(Path.join(base, "20260812000011_create_memory_recall_traces.exs"))

    Code.require_file(
      Path.join(base, "20260812000012_add_memory_recall_inspector_trace_fields.exs")
    )
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.Recall.TraceInspectorMigrationTestRepo, config})
    Backplane.Memory.Recall.TraceInspectorMigrationTestRepo
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
