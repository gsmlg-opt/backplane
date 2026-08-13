defmodule Backplane.Memory.Recall.StoreTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Recall.{
    Candidate,
    Packer,
    PostFusion,
    QueryPlan,
    Reranker,
    Run,
    Store,
    TraceCandidate
  }

  @partition %{host_id: "host-a", client_id: "client-a", scope: "team", namespace: "private"}

  test "create is privacy-safe and idempotent, while conflicting retries are rejected" do
    request_id = unique("request")
    assert {:ok, plan} = plan("token=super-secret find auth")

    assert {:ok, first} =
             Store.create(plan,
               request_id: request_id,
               correlation_id: "correlation-a",
               query_embedding_model: "api_key=do-not-store embed-v1"
             )

    assert {:ok, replay} =
             Store.create(plan,
               request_id: request_id,
               correlation_id: "correlation-a",
               query_embedding_model: "api_key=do-not-store embed-v1"
             )

    assert replay.id == first.id

    assert {:error, :idempotency_conflict} =
             Store.create(plan,
               request_id: request_id,
               correlation_id: "correlation-a",
               query_embedding_model: "different-model"
             )

    refute first.normalized_query =~ "super-secret"
    refute inspect(first.query_plan) =~ "super-secret"
    refute inspect(first.query_embedding_model) =~ "do-not-store"
    assert byte_size(first.query_hash) == 32

    assert {:ok, other_plan} = plan("different")

    assert {:error, :idempotency_conflict} =
             Store.create(other_plan, request_id: request_id, correlation_id: "correlation-a")

    assert {:ok, hinted_plan} =
             QueryPlan.new(
               Map.merge(@partition, %{
                 query: "safe",
                 entity_hints: ["api_key=do-not-store"]
               })
             )

    assert {:ok, hinted} =
             Store.create(hinted_plan, request_id: unique("request"), correlation_id: "c")

    refute inspect(hinted.filters) =~ "do-not-store"

    assert {:error, {:unknown_options, [:unknown]}} =
             Store.create(plan,
               request_id: unique("request"),
               correlation_id: "c",
               unknown: true
             )
  end

  test "concurrent identical creates converge on one run" do
    assert {:ok, query_plan} = plan("concurrent")
    request_id = unique("concurrent-request")

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Store.create(query_plan, request_id: request_id, correlation_id: "c")
        end)
      end

    ids =
      Enum.map(tasks, fn task ->
        assert {:ok, %Run{id: id}} = Task.await(task)
        id
      end)

    assert [_one] = Enum.uniq(ids)
    assert repo().aggregate(from(r in Run, where: r.request_id == ^request_id), :count) == 1
  end

  test "candidate upsert is bounded, partition-safe, and never persists content" do
    assert {:ok, query_plan} = plan("trace")

    assert {:ok, run} =
             Store.create(query_plan, request_id: unique("request"), correlation_id: "c")

    assert {:ok, candidate} = candidate("private candidate content")

    trace = %{
      candidate: candidate,
      selected: true,
      ranks: %{fts: 1},
      scores: %{fts: 0.8, rrf: 0.016},
      pre_reranker_rank: 1,
      post_reranker_rank: 2,
      token_estimate: 7
    }

    assert {:ok, [%TraceCandidate{} = row]} = Store.put_candidates(run.id, @partition, [trace])
    assert row.candidate_id == candidate.id

    assert row.source_refs == %{
             "refs" => [%{"type" => "event", "id" => hd(candidate.source_ids)}]
           }

    assert row.pre_reranker_rank == 1
    assert row.post_reranker_rank == 2

    updated =
      Map.merge(trace, %{
        selected: false,
        rejection_reason: "diversity",
        scores: %{fts: 0.8, rrf: 0.02}
      })

    assert {:ok, [%TraceCandidate{}]} = Store.put_candidates(run.id, @partition, [updated])

    assert [%TraceCandidate{selected: false, rejection_reason: "diversity", rrf_score: 0.02}] =
             repo().all(from(c in TraceCandidate, where: c.recall_run_id == ^run.id))

    refute inspect(repo().all(TraceCandidate)) =~ "private candidate content"

    assert {:error, :not_found} =
             Store.put_candidates(run.id, %{@partition | host_id: "other"}, [trace])

    assert {:error, :too_many_candidates} =
             Store.put_candidates(run.id, @partition, List.duplicate(trace, 501))

    assert {:error, {:unknown_trace_keys, [:unknown]}} =
             Store.put_candidates(run.id, @partition, [Map.put(trace, :unknown, true)])
  end

  test "trace candidate changeset enforces exact closed typed provenance" do
    source_id = Ecto.UUID.generate()

    base = %{
      recall_run_id: Ecto.UUID.generate(),
      host_id: "host-a",
      client_id: "client-a",
      scope: "team",
      namespace: "private",
      candidate_id: Ecto.UUID.generate(),
      candidate_kind: "memory",
      memory_type: "semantic",
      source_ids: [source_id],
      source_refs: %{"refs" => [%{"type" => "event", "id" => source_id}]},
      channel_scores: %{},
      selected: false,
      rejection_reason: "review",
      token_estimate: 1
    }

    assert TraceCandidate.changeset(%TraceCandidate{}, base).valid?

    invalid_refs = [
      %{"refs" => [%{"id" => source_id}]},
      %{"refs" => [%{"type" => "event", "id" => source_id, "content" => "private"}]},
      %{"refs" => [%{"type" => "event", "id" => "not-a-uuid"}]},
      %{"refs" => [%{"type" => "unknown", "id" => source_id}]},
      %{"refs" => [%{"type" => "event", "id" => Ecto.UUID.generate()}]}
    ]

    for source_refs <- invalid_refs do
      refute TraceCandidate.changeset(%TraceCandidate{}, %{base | source_refs: source_refs}).valid?
    end
  end

  test "finalize atomically replaces the candidate truth and derives selected totals" do
    assert {:ok, query_plan} = plan("finalize")

    assert {:ok, run} =
             Store.create(query_plan, request_id: unique("request"), correlation_id: "c")

    assert {:ok, candidate} = candidate("result")

    trace = %{
      candidate: candidate,
      selected: true,
      ranks: %{fts: 1},
      scores: %{fts: 0.7, final: 0.9}
    }

    assert {:error, {:unknown_options, [:tokens_used]}} =
             Store.finalize(run.id, @partition, [trace], tokens_used: 1)

    assert repo().aggregate(from(c in TraceCandidate, where: c.recall_run_id == ^run.id), :count) ==
             0

    assert %Run{status: "running"} = repo().get!(Run, run.id)

    invalid_trace = Map.put(trace, :selected, "true")

    assert {:error, {:invalid, :selected}} =
             Store.finalize(run.id, @partition, [trace, invalid_trace], latency_ms: 10)

    assert repo().aggregate(from(c in TraceCandidate, where: c.recall_run_id == ^run.id), :count) ==
             0

    stale_candidate = candidate("stale") |> elem(1)

    assert {:ok, _} =
             Store.put_candidates(run.id, @partition, [
               %{
                 candidate: stale_candidate,
                 selected: false,
                 rejection_reason: "review",
                 scores: %{final: 0.1}
               }
             ])

    attrs = [
      latency_ms: 12,
      channel_availability: %{"fts" => true, "vector" => false},
      channel_errors: %{"vector" => "token=do-not-store unavailable"},
      query_embedding_model: "api_key=do-not-store embed-v1",
      reranker_provider: "proxy-main",
      reranker_status: "provider_error",
      reranker_error_class: "api_key=do-not-store provider_error",
      reranker_duration_ms: 7
    ]

    assert {:ok, %Run{status: "complete", tokens_used: 2, result_count: 1} = complete} =
             Store.finalize(run.id, @partition, [trace], attrs)

    refute inspect(complete) =~ "do-not-store"
    assert complete.reranker_provider == "proxy-main"
    assert complete.reranker_status == "provider_error"
    assert complete.reranker_duration_ms == 7
    assert is_binary(complete.terminal_digest) and byte_size(complete.terminal_digest) == 32

    assert {:ok, %Run{id: id}} = Store.finalize(run.id, @partition, [trace], attrs)
    assert id == complete.id

    assert repo().aggregate(from(c in TraceCandidate, where: c.recall_run_id == ^run.id), :count) ==
             1

    assert [%TraceCandidate{candidate_id: id, selected: true, rejection_reason: nil}] =
             repo().all(from(c in TraceCandidate, where: c.recall_run_id == ^run.id))

    assert id == candidate.id

    changed_trace = put_in(trace, [:scores, :final], 0.8)

    assert {:error, :already_finalized} =
             Store.finalize(run.id, @partition, [changed_trace], attrs)
  end

  test "candidate selection truth and terminal digest reject ambiguity and mismatched retries" do
    assert {:ok, query_plan} = plan("selection truth")

    assert {:ok, run} =
             Store.create(query_plan, request_id: unique("request"), correlation_id: "c")

    assert {:ok, candidate} = candidate("result")

    assert {:error, {:invalid, :rejection_reason}} =
             Store.put_candidates(run.id, @partition, [
               %{candidate: candidate, selected: false, scores: %{final: 0.1}}
             ])

    assert {:error, {:invalid, :rejection_reason}} =
             Store.put_candidates(run.id, @partition, [
               %{
                 candidate: candidate,
                 selected: true,
                 rejection_reason: "diversity",
                 scores: %{final: 0.9}
               }
             ])

    rejected = %{
      candidate: candidate,
      selected: false,
      rejection_reason: "below_threshold",
      scores: %{final: 0.1}
    }

    assert {:error, :duplicate_candidates} =
             Store.finalize(run.id, @partition, [rejected, rejected], latency_ms: 1)

    assert {:ok, failed} =
             Store.fail(run.id, @partition,
               failure_class: "token=do-not-store provider",
               channel_errors: %{"vector" => "api_key=do-not-store"}
             )

    refute inspect(failed) =~ "do-not-store"

    assert {:ok, replay} =
             Store.fail(run.id, @partition,
               failure_class: "token=do-not-store provider",
               channel_errors: %{"vector" => "api_key=do-not-store"}
             )

    assert replay.id == failed.id

    assert {:error, :already_finalized} =
             Store.fail(run.id, @partition,
               failure_class: "different",
               channel_errors: %{"vector" => "different"}
             )
  end

  test "concurrent identical finalizations converge on the canonical terminal digest" do
    assert {:ok, query_plan} = plan("concurrent finalize")

    assert {:ok, run} =
             Store.create(query_plan, request_id: unique("request"), correlation_id: "c")

    assert {:ok, candidate} = candidate("same result")
    trace = %{candidate: candidate, selected: true, scores: %{final: 0.9}}
    attrs = [latency_ms: 8, channel_availability: %{"fts" => true}]

    results =
      1..6
      |> Task.async_stream(fn _ -> Store.finalize(run.id, @partition, [trace], attrs) end,
        max_concurrency: 6,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Run{status: "complete"}}, &1))

    assert [_digest] =
             results |> Enum.map(fn {:ok, result} -> result.terminal_digest end) |> Enum.uniq()
  end

  test "trace persistence exposes an explicit orchestrator bypass" do
    assert is_boolean(Store.enabled?())
  end

  test "post-fusion reranking and packing produce Store-compatible trace rows" do
    assert {:ok, query_plan} = plan("pipeline trace")

    assert {:ok, run} =
             Store.create(query_plan, request_id: unique("request"), correlation_id: "pipeline")

    assert {:ok, first} = candidate("first")
    assert {:ok, second} = candidate("second")

    fused = [
      %{candidate: first, ranks: %{fts: 1}, scores: %{rrf: 0.9}},
      %{candidate: second, ranks: %{fts: 2}, scores: %{rrf: 0.8}}
    ]

    assert {:ok, post_fusion} = PostFusion.apply(fused)
    provider = fn _, _ -> {:ok, [%{token: 1, score: 0.9}, %{token: 0, score: 0.4}]} end
    task_supervisor = start_supervised!({Task.Supervisor, name: unique_supervisor()})

    assert {:ok, reranked, %{status: :ok}} =
             Reranker.apply(post_fusion, "pipeline trace",
               enabled: true,
               model: "test-model",
               provider: provider,
               task_supervisor: task_supervisor
             )

    assert {:ok, packed, %{used_tokens: used}} = Packer.pack(reranked, 100)
    assert used <= 100

    assert {:ok, %Run{status: "complete"}} =
             Store.finalize(run.id, @partition, packed, latency_ms: 1)

    assert {:ok, _stored_run, stored} = Store.get(run.id, @partition)
    assert length(stored) == 2
    assert Enum.all?(stored, &(&1.selected and is_nil(&1.rejection_reason)))
    assert Enum.all?(stored, &is_number(&1.reranker_score))
  end

  test "fail and trace reads require exact partitions and use bounded stable pagination" do
    for index <- 1..3 do
      assert {:ok, query_plan} = plan("query #{index}")

      assert {:ok, run} =
               Store.create(query_plan, request_id: unique("request"), correlation_id: "c")

      assert {:ok, %Run{status: "failed"} = failed} =
               Store.fail(run.id, @partition,
                 failure_class: "vector_provider",
                 channel_errors: %{"vector" => "token=do-not-store timeout"}
               )

      refute inspect(failed.channel_errors) =~ "do-not-store"
    end

    assert {:ok, %{runs: [first, second], next_cursor: cursor}} = Store.list(@partition, limit: 2)
    assert is_binary(cursor)
    assert first.id != second.id

    assert {:ok, %{runs: [_third], next_cursor: nil}} =
             Store.list(@partition, limit: 2, cursor: cursor)

    assert {:error, :invalid_cursor} = Store.list(@partition, limit: 2, cursor: "bad")
    assert {:error, {:invalid, :limit}} = Store.list(@partition, limit: 101)
    assert {:error, {:unknown_options, [:unknown]}} = Store.list(@partition, unknown: true)
    assert {:error, :not_found} = Store.get(first.id, %{@partition | client_id: "other"})
    assert {:ok, %Run{id: id}, []} = Store.get(first.id, @partition)
    assert id == first.id
  end

  test "list validates and applies closed Inspector filters before a stable cursor" do
    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    runs =
      for {index, status, correlation} <- [
            {1, "failed", "corr-a"},
            {2, "complete", "corr-a"},
            {3, "failed", "corr-b"},
            {4, "running", "corr-a"}
          ] do
        assert {:ok, query_plan} = plan("filter #{index}")

        assert {:ok, run} =
                 Store.create(query_plan,
                   request_id: unique("filter-request"),
                   correlation_id: correlation
                 )

        run =
          case status do
            "failed" -> Store.fail(run.id, @partition, failure_class: "provider") |> elem(1)
            "complete" -> Store.finalize(run.id, @partition, [], latency_ms: 1) |> elem(1)
            "running" -> run
          end

        inserted_at = DateTime.add(base, index, :second)

        repo().update_all(from(item in Run, where: item.id == ^run.id),
          set: [inserted_at: inserted_at, updated_at: inserted_at]
        )

        %{run | inserted_at: inserted_at}
      end

    from_time = DateTime.add(base, 1, :second)
    to_time = DateTime.add(base, 3, :second)

    assert {:ok, %{runs: [page_one], next_cursor: cursor}} =
             Store.list(@partition,
               status: "failed",
               correlation_id: " corr-a ",
               from: from_time,
               to: to_time,
               limit: 1
             )

    assert page_one.id == Enum.at(runs, 0).id
    assert is_nil(cursor)

    assert {:ok, %{runs: [newer_failed], next_cursor: failed_cursor}} =
             Store.list(@partition, status: "failed", limit: 1)

    assert newer_failed.id == Enum.at(runs, 2).id
    assert is_binary(failed_cursor)

    assert {:ok, %{runs: [older_failed], next_cursor: nil}} =
             Store.list(@partition, status: "failed", limit: 1, cursor: failed_cursor)

    assert older_failed.id == Enum.at(runs, 0).id

    assert {:error, {:invalid, :status}} = Store.list(@partition, status: "unknown")
    assert {:error, {:invalid, :correlation_id}} = Store.list(@partition, correlation_id: " ")
    assert {:error, {:invalid, :from}} = Store.list(@partition, from: NaiveDateTime.utc_now())

    assert {:error, {:invalid, :time_range}} =
             Store.list(@partition, from: to_time, to: from_time)
  end

  defp plan(query), do: QueryPlan.new(Map.put(@partition, :query, query))

  defp candidate(content) do
    source_id = Ecto.UUID.generate()

    Candidate.new(
      Map.merge(@partition, %{
        id: Ecto.UUID.generate(),
        kind: :memory,
        memory_type: :semantic,
        content: content,
        source_ids: [source_id],
        source_refs: [%{type: :event, id: source_id}]
      })
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_supervisor,
    do: String.to_atom("store-reranker-#{System.unique_integer([:positive])}")
end
