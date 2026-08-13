defmodule Backplane.Memory.Operations.DashboardMetrics do
  @moduledoc "Durable and explicitly sourced operational metrics for the Memory overview."

  import Ecto.Query

  alias Backplane.Memory.Embedding.CircuitBreaker
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProjectedSession, State}

  @memory_queues ~w(memory memory_crystals memory_lessons memory_relation_classifier)
  @pending_job_states ~w(available scheduled executing retryable)
  @failed_job_states ~w(retryable discarded)
  @backlog_workers %{
    embedding: ["Backplane.Memory.Workers.EmbedWorker", "BackplaneMemory.Workers.EmbedWorker"],
    consolidation: [
      "BackplaneMemory.Workers.EpisodicWorker",
      "BackplaneMemory.Workers.ProceduralWorker",
      "BackplaneMemory.Workers.SummaryWorker",
      "Backplane.Memory.Workers.EpisodicWorker",
      "Backplane.Memory.Workers.ProceduralWorker",
      "Backplane.Memory.Workers.SummaryWorker"
    ],
    graph: [
      "Backplane.Memory.Workers.GraphExtractWorker",
      "BackplaneMemory.Workers.GraphExtractWorker"
    ],
    profile: [
      "Backplane.Memory.Workers.ProfileBuildWorker",
      "BackplaneMemory.Workers.ProfileBuildWorker"
    ],
    lesson: [
      "Backplane.Memory.Workers.LessonCandidateWorker",
      "Backplane.Memory.Workers.LessonDecayWorker",
      "Backplane.Memory.Workers.LessonDecaySweepWorker"
    ],
    crystal: ["Backplane.Memory.Workers.CrystalWorker"]
  }

  def snapshot(now \\ DateTime.utc_now())

  def snapshot(%DateTime{} = now) do
    cutoff = DateTime.add(now, -24, :hour)
    queues = queue_metrics()

    %{
      ingestion: ingestion(cutoff),
      processing: processing(now, queues),
      recall: recall(cutoff),
      knowledge: knowledge(),
      coordination: coordination(now),
      token_usage: actual_llm_usage(cutoff)
    }
  end

  defp ingestion(cutoff) do
    counters = Backplane.Metrics.snapshot() |> Map.get(:counters, %{})

    %{
      accepted_24h: repo().aggregate(from(e in Event, where: e.inserted_at >= ^cutoff), :count),
      duplicates: telemetry_value(counters, "memory_events_duplicates"),
      rejections: %{status: :unavailable, value: nil},
      failures: telemetry_value(counters, "memory_events_errors"),
      sequence_gaps:
        repo().one(from(s in ProjectedSession, select: coalesce(sum(s.gap_count), 0))) || 0
    }
  end

  defp processing(now, queues) do
    projection_counts = grouped_counts(State, :status)

    oldest =
      repo().one(
        from(s in State,
          where: s.status in ["pending", "enqueued", "running", "failed", "dead_letter"],
          select: min(s.updated_at)
        )
      )

    %{
      projections: projection_counts,
      projection_lag:
        if(oldest,
          do: %{
            status: :available,
            milliseconds: max(DateTime.diff(now, oldest, :millisecond), 0)
          },
          else: %{status: :unavailable, milliseconds: nil}
        ),
      queues: queues,
      failed_workers: failed_workers(),
      backlogs: backlog_counts(),
      circuit_breaker: %{state: CircuitBreaker.state(), source: :runtime_telemetry}
    }
  end

  defp queue_metrics do
    sql = """
    SELECT queue,
           count(*) FILTER (WHERE state = ANY($2))::bigint AS depth,
           count(*) FILTER (WHERE state = ANY($3))::bigint AS failures,
           count(*) FILTER (WHERE state = 'discarded')::bigint AS dead_letters
    FROM oban_jobs
    WHERE queue = ANY($1)
    GROUP BY queue
    ORDER BY queue
    """

    repo().query!(sql, [@memory_queues, @pending_job_states, @failed_job_states]).rows
    |> Enum.map(fn [queue, depth, failures, dead_letters] ->
      %{
        queue: queue,
        depth: depth,
        failures: failures,
        dead_letters: dead_letters,
        detail_path: "/system/logs"
      }
    end)
  end

  defp failed_workers do
    sql = """
    SELECT id, queue, worker, state
    FROM oban_jobs
    WHERE queue = ANY($1) AND state = ANY($2)
    ORDER BY attempted_at DESC NULLS LAST, id DESC
    LIMIT 20
    """

    repo().query!(sql, [@memory_queues, @failed_job_states]).rows
    |> Enum.map(fn [id, queue, worker, state] ->
      %{
        id: id,
        queue: queue,
        worker: worker,
        state: state,
        detail_path: "/system/logs?job_id=#{id}"
      }
    end)
  end

  defp backlog_counts do
    sql = """
    SELECT worker, count(*)::bigint
    FROM oban_jobs
    WHERE state = ANY($1)
    GROUP BY worker
    """

    counts = repo().query!(sql, [@pending_job_states]).rows |> Map.new(fn [k, v] -> {k, v} end)

    Map.new(@backlog_workers, fn {kind, workers} ->
      {kind, Enum.sum(Enum.map(workers, &Map.get(counts, &1, 0)))}
    end)
  end

  defp recall(cutoff) do
    sql = """
    SELECT count(*)::bigint,
           count(*) FILTER (WHERE status = 'failed')::bigint,
           count(*) FILTER (WHERE status = 'complete')::bigint,
           percentile_disc(0.50) WITHIN GROUP (ORDER BY latency_ms)
             FILTER (WHERE status = 'complete' AND latency_ms IS NOT NULL),
           percentile_disc(0.95) WITHIN GROUP (ORDER BY latency_ms)
             FILTER (WHERE status = 'complete' AND latency_ms IS NOT NULL),
           count(*) FILTER (WHERE status = 'complete' AND result_count = 0)::bigint,
           coalesce(sum(tokens_used) FILTER (WHERE status = 'complete'), 0)::bigint,
           coalesce(sum(token_budget) FILTER (WHERE status = 'complete'), 0)::bigint,
           count(*) FILTER (
             WHERE status = 'complete' AND reranker_status IS NOT NULL
               AND reranker_status NOT IN ('disabled', 'empty')
           )::bigint,
           count(*) FILTER (
             WHERE status = 'complete'
               AND reranker_status IN ('unavailable', 'provider_error', 'exit', 'timeout', 'malformed', 'error')
           )::bigint,
           count(*) FILTER (
             WHERE status = 'complete'
               AND channel_availability->>'fts' IN ('true', 'available', 'ok')
               AND coalesce(channel_availability->>'vector' IN ('true', 'available', 'ok'), false) = false
           )::bigint,
           count(*) FILTER (WHERE channel_availability->>'fts' IN ('true', 'available', 'ok'))::bigint,
           count(*) FILTER (WHERE channel_availability->>'fts' IN ('false', 'unavailable', 'failed', 'error'))::bigint,
           count(*) FILTER (WHERE channel_availability->>'vector' IN ('true', 'available', 'ok'))::bigint,
           count(*) FILTER (WHERE channel_availability->>'vector' IN ('false', 'unavailable', 'failed', 'error'))::bigint,
           count(*) FILTER (WHERE channel_availability->>'graph' IN ('true', 'available', 'ok'))::bigint,
           count(*) FILTER (WHERE channel_availability->>'graph' IN ('false', 'unavailable', 'failed', 'error'))::bigint,
           count(*) FILTER (WHERE coalesce(channel_errors->>'fts', '') NOT IN ('', 'false'))::bigint,
           count(*) FILTER (WHERE coalesce(channel_errors->>'vector', '') NOT IN ('', 'false'))::bigint,
           count(*) FILTER (WHERE coalesce(channel_errors->>'graph', '') NOT IN ('', 'false'))::bigint
    FROM memory_recall_runs
    WHERE inserted_at >= $1
    """

    [
      [
        count,
        failures,
        complete_count,
        p50,
        p95,
        empty_count,
        used,
        budget,
        reranked,
        reranker_failures,
        fallbacks,
        fts_available,
        fts_degraded,
        vector_available,
        vector_degraded,
        graph_available,
        graph_degraded,
        fts_failures,
        vector_failures,
        graph_failures
      ]
    ] = repo().query!(sql, [cutoff]).rows

    %{
      count: count,
      failures: failures,
      latency: %{p50_ms: p50, p95_ms: p95},
      empty_rate_percent: percentage(empty_count, complete_count),
      budget_utilization_percent: percentage(used, budget),
      channels: %{
        fts: channel_state(fts_available, fts_degraded, fts_failures),
        vector: channel_state(vector_available, vector_degraded, vector_failures),
        graph: channel_state(graph_available, graph_degraded, graph_failures)
      },
      channel_failures: %{
        fts: fts_failures,
        vector: vector_failures,
        graph: graph_failures
      },
      reranker: %{used: reranked, failures: reranker_failures},
      fallback_rate_percent: percentage(fallbacks, complete_count),
      estimated_token_reduction: estimated_token_reduction(cutoff)
    }
  end

  defp channel_state(_available, degraded, failures) when degraded > 0 or failures > 0,
    do: :degraded

  defp channel_state(available, _degraded, _failures) when available > 0, do: :available
  defp channel_state(_available, _degraded, _failures), do: :unavailable

  defp estimated_token_reduction(cutoff) do
    sql = """
    SELECT count(*)::bigint,
           coalesce(sum(candidate.token_estimate) FILTER (WHERE candidate.selected = false), 0)::bigint
    FROM memory_recall_candidates candidate
    JOIN memory_recall_runs run ON run.id = candidate.recall_run_id
    WHERE run.inserted_at >= $1
    """

    case repo().query!(sql, [cutoff]).rows do
      [[0, _tokens]] -> %{status: :unavailable, tokens: nil}
      [[_count, tokens]] -> %{status: :estimated, tokens: tokens}
    end
  end

  defp actual_llm_usage(cutoff) do
    sql = """
    SELECT count(*)::bigint, coalesce(sum(input_tokens), 0)::bigint,
           coalesce(sum(output_tokens), 0)::bigint
    FROM llm_logs WHERE inserted_at >= $1
    """

    [[requests, input, output]] = repo().query!(sql, [cutoff]).rows

    %{
      label: "Actual LLM Proxy usage",
      source: :llm_proxy_logs,
      status: :available,
      requests: requests,
      input_tokens: input,
      output_tokens: output
    }
  rescue
    _ ->
      %{
        label: "Actual LLM Proxy usage",
        source: :llm_proxy_logs,
        status: :unavailable,
        requests: nil,
        input_tokens: nil,
        output_tokens: nil
      }
  end

  defp knowledge do
    %{
      memories_by_type: grouped_sql("bpm_memories", "memory_type", "deleted_at IS NULL"),
      memories_by_lifecycle: grouped_sql("bpm_memories", "lifecycle_state", "deleted_at IS NULL"),
      lessons_by_state: grouped_sql("memory_lessons", "status"),
      crystals: scalar("SELECT count(*)::bigint FROM memory_crystals WHERE status = 'complete'"),
      graph_nodes: scalar("SELECT count(*)::bigint FROM memory_graph_nodes"),
      graph_edges: scalar("SELECT count(*)::bigint FROM memory_graph_edges"),
      pending_contradictions:
        scalar(
          "SELECT count(*)::bigint FROM bpm_memory_relations WHERE classification = 'contradiction' AND status = 'candidate'"
        )
    }
  end

  defp coordination(now) do
    %{
      actions_by_status: grouped_sql("memory_actions", "status"),
      frontier_size:
        scalar(
          "SELECT count(*)::bigint FROM memory_actions WHERE status IN ('pending', 'blocked')"
        ),
      active_leases:
        scalar("SELECT count(*)::bigint FROM memory_leases WHERE expires_at >= $1", [now]),
      expired_leases:
        scalar("SELECT count(*)::bigint FROM memory_leases WHERE expires_at < $1", [now]),
      unread_signals: scalar("SELECT count(*)::bigint FROM memory_signals WHERE read_at IS NULL")
    }
  end

  defp grouped_counts(schema, field) do
    schema
    |> group_by([row], field(row, ^field))
    |> select([row], {field(row, ^field), count()})
    |> repo().all()
    |> Map.new()
  end

  defp grouped_sql(table, column, where \\ "TRUE") do
    repo().query!(
      "SELECT #{column}, count(*)::bigint FROM #{table} WHERE #{where} GROUP BY #{column}"
    ).rows
    |> Map.new(fn [key, count] -> {key, count} end)
  end

  defp scalar(sql, params \\ []), do: repo().query!(sql, params).rows |> hd() |> hd()

  defp telemetry_value(counters, name),
    do: %{status: :available, value: Map.get(counters, name, 0), source: :runtime_telemetry}

  defp percentage(_value, 0), do: nil
  defp percentage(value, total), do: Float.round(value / total * 100, 1)

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
