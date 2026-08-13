defmodule Backplane.Memory.Operations.DashboardMetricsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Operations.DashboardMetrics
  alias Backplane.Memory.Projections.State
  alias Backplane.Memory.Recall.{QueryPlan, Store}

  @partition %{
    host_id: "dashboard-host",
    client_id: "dashboard-client",
    scope: "team",
    namespace: "private"
  }

  test "empty durable sources remain explicit instead of fabricating dashboard values" do
    reset_dashboard_sources()

    assert %{
             ingestion: ingestion,
             processing: processing,
             recall: recall,
             knowledge: knowledge,
             coordination: coordination,
             token_usage: token_usage
           } = DashboardMetrics.snapshot(~U[2030-08-12 12:00:00.000000Z])

    assert ingestion.sequence_gaps == 0
    assert ingestion.rejections == %{status: :unavailable, value: nil}
    assert processing.projection_lag == %{status: :unavailable, milliseconds: nil}
    assert processing.queues == []
    assert processing.circuit_breaker.source == :runtime_telemetry
    assert recall.count == 0
    assert recall.latency == %{p50_ms: nil, p95_ms: nil}
    assert recall.channels == %{fts: :unavailable, vector: :unavailable, graph: :unavailable}
    assert recall.estimated_token_reduction == %{status: :unavailable, tokens: nil}
    assert token_usage.label == "Actual LLM Proxy usage"
    assert token_usage.source == :llm_proxy_logs
    assert is_map(knowledge.memories_by_type)
    assert is_map(coordination.actions_by_status)
  end

  test "durable processing and recall rows drive actionable rates and latency percentiles" do
    reset_dashboard_sources()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %State{}
    |> State.changeset(%{
      projector: "session",
      subject_type: "session",
      subject_id: "dashboard-subject",
      processing_version: "dashboard-v1",
      status: "failed",
      attempt_count: 3,
      last_error: "projection failed"
    })
    |> repo().insert!()

    Backplane.Memory.Workers.EmbedWorker.new(%{"id" => Ecto.UUID.generate()})
    |> repo().insert!()

    failed_job =
      Backplane.Memory.Workers.GraphExtractWorker.new(%{"session_id" => "failed-dashboard"})
      |> repo().insert!()

    repo().update_all(
      from(job in "oban_jobs", where: job.id == ^failed_job.id),
      set: [state: "discarded", attempted_at: now, errors: [%{"error" => "graph failed"}]]
    )

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(@partition, %{query: "dashboard recall", token_budget: 100}))

    for {latency, availability, errors, reranker_status, result_count} <- [
          {10, %{"fts" => true, "vector" => false, "graph" => false}, %{"vector" => "timeout"},
           "provider_error", 0},
          {90, %{"fts" => true, "vector" => true, "graph" => false}, %{}, "ok", 2}
        ] do
      assert {:ok, run} =
               Store.create(plan,
                 request_id: Ecto.UUID.generate(),
                 correlation_id: Ecto.UUID.generate()
               )

      traces =
        for index <- if(result_count == 0, do: [], else: 1..result_count) do
          source_id = Ecto.UUID.generate()

          assert {:ok, candidate} =
                   Backplane.Memory.Recall.Candidate.new(
                     Map.merge(@partition, %{
                       id: Ecto.UUID.generate(),
                       kind: :memory,
                       memory_type: :semantic,
                       content: "dashboard candidate #{index}",
                       source_ids: [source_id],
                       source_refs: [%{type: :event, id: source_id}],
                       inserted_at: now
                     })
                   )

          %{
            candidate: candidate,
            selected: true,
            ranks: %{fts: index},
            scores: %{fts: 1.0 / index, final: 1.0 / index},
            token_estimate: 10
          }
        end

      assert {:ok, _run} =
               Store.finalize(run.id, @partition, traces,
                 latency_ms: latency,
                 channel_availability: availability,
                 channel_errors: errors,
                 reranker_status: reranker_status
               )
    end

    snapshot = DashboardMetrics.snapshot(now)

    assert snapshot.processing.projections["failed"] == 1

    assert [%{queue: "memory", depth: 1, failures: 1, dead_letters: 1}] =
             Enum.map(
               snapshot.processing.queues,
               &Map.take(&1, [:queue, :depth, :failures, :dead_letters])
             )

    assert snapshot.processing.backlogs.embedding == 1

    assert [
             %{
               id: failed_job_id,
               worker: "Backplane.Memory.Workers.GraphExtractWorker",
               state: "discarded",
               detail_path: detail_path
             }
           ] = snapshot.processing.failed_workers

    assert failed_job_id == failed_job.id
    assert detail_path == "/system/logs?job_id=#{failed_job.id}"
    refute Map.has_key?(hd(snapshot.processing.failed_workers), :errors)

    assert snapshot.recall.count == 2
    assert snapshot.recall.latency == %{p50_ms: 10, p95_ms: 90}
    assert snapshot.recall.empty_rate_percent == 50.0
    assert snapshot.recall.fallback_rate_percent == 50.0
    assert snapshot.recall.channels == %{fts: :available, vector: :degraded, graph: :degraded}
    assert snapshot.recall.channel_failures == %{fts: 0, vector: 1, graph: 0}
    assert snapshot.recall.reranker == %{used: 2, failures: 1}
  end

  defp reset_dashboard_sources do
    for table <- [
          "memory_recall_candidates",
          "memory_recall_runs",
          "bpm_projection_states",
          "oban_jobs",
          "llm_logs"
        ] do
      repo().query!("DELETE FROM #{table}")
    end
  end
end
