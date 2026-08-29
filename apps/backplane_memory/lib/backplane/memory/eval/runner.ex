defmodule Backplane.Memory.Eval.Runner do
  @moduledoc "Database-backed M15 benchmark orchestration for `Backplane.Memory.Eval`."

  import Ecto.Query

  alias Backplane.Memory.Eval
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Events.Stream, as: EventStream
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Qualification.Profile
  alias Backplane.Memory.Recall.Pipeline
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  @warmups 5
  @samples 100

  def seed(fixture) do
    Enum.reduce_while(fixture["memories"], {:ok, %{}}, fn memory, {:ok, ids} ->
      opts = [
        type: "semantic",
        agent_id: "memory-eval-agent",
        host_id: memory["host_id"],
        client_id: memory["client_id"],
        scope: memory["scope"],
        namespace: memory["namespace"],
        session_id: memory["session_id"],
        metadata: %{
          "fixture_id" => fixture["fixture_id"],
          "fixture_memory_id" => memory["fixture_memory_id"],
          "derived" => memory["derived"] == true
        },
        idempotency_scope: fixture["fixture_id"],
        idempotency_key: memory["fixture_memory_id"]
      ]

      case Memories.remember(memory["content"], opts) do
        {:ok, record} -> {:cont, {:ok, Map.put(ids, memory["fixture_memory_id"], record.id)}}
        {:error, reason} -> {:halt, {:error, {:seed_failed, memory["fixture_memory_id"], reason}}}
      end
    end)
  end

  def run(opts \\ []) do
    fixture_result =
      case Keyword.get(opts, :fixture_path) do
        nil -> Eval.load_fixture()
        path -> Eval.load_fixture(path)
      end

    with {:ok, fixture} <- fixture_result do
      with {:ok, ids} <- seed(fixture),
           {:ok, derived} <- seed_derived(fixture) do
        evaluate(fixture, opts |> Keyword.put(:seed_ids, ids) |> Keyword.put(:derived, derived))
      end
    end
  end

  def sandboxed_run(opts \\ []) do
    repo = repo()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
    Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

    try do
      run(opts)
    after
      Ecto.Adapters.SQL.Sandbox.checkin(repo)
    end
  end

  def sandboxed_seed(fixture) do
    repo = repo()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
    Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

    try do
      seed(fixture)
    after
      Ecto.Adapters.SQL.Sandbox.checkin(repo)
    end
  end

  def evaluate(fixture, opts \\ []) do
    warmups = Keyword.get(opts, :warmups, @warmups)
    samples = Keyword.get(opts, :samples, @samples)

    if warmups < 5 do
      {:error, :insufficient_warmups}
    else
      evaluate_validated(fixture, opts, warmups, samples)
    end
  end

  defp evaluate_validated(fixture, opts, warmups, samples) do
    pipeline = Keyword.get(opts, :pipeline, &Pipeline.run/2)
    profile = Keyword.get(opts, :profile, :performance)
    thresholds = Profile.thresholds(profile).eval
    content_ids = Map.new(fixture["memories"], &{&1["content"], &1["fixture_memory_id"]})

    Enum.each(Enum.take(Stream.cycle(fixture["queries"]), warmups), fn query ->
      pipeline.(attrs(fixture, query), pipeline_opts())
    end)

    measured =
      Enum.map(Enum.take(Stream.cycle(fixture["queries"]), samples), fn query ->
        timed_pipeline(pipeline, fixture, query, content_ids)
      end)

    first_by_query = Map.new(measured, &{&1.query_id, &1})

    quality_cases =
      Enum.map(fixture["queries"], fn query ->
        %{relevant: query["relevant_ids"], returned: first_by_query[query["query_id"]].returned}
      end)

    derived_returned =
      derived_provenance_cases(fixture, pipeline, Keyword.get(opts, :derived, []))

    outage = outage_cases(fixture, pipeline, samples)

    report = %{
      schema_version: 2,
      profile: profile,
      performance_authoritative: Profile.authoritative?(profile),
      effective_thresholds: thresholds,
      fixture_id: fixture["fixture_id"],
      label: "Backplane coding-corpus retrieval evaluation",
      directly_comparable_to_longmemeval: false,
      configuration: %{
        top_k: 5,
        reranker: "disabled",
        token_budget: 100_000,
        warmups: warmups,
        measured_sample_count: samples,
        sample_semantics: "total round-robin query executions, not samples per query",
        retrieval_fusion_semantics:
          "Pipeline retrieval plus post-fusion telemetry; excludes embedding and LLM",
        e2e_semantics: "Pipeline wall time with reranker disabled"
      },
      quality: Eval.quality_metrics(quality_cases, 5),
      outage: outage,
      provenance: provenance_metrics(derived_returned),
      latency: %{
        retrieval_fusion: latency(measured, & &1.retrieval_fusion_ms),
        e2e: latency(measured, & &1.e2e_ms)
      }
    }

    report = Map.put(report, :thresholds, threshold_verdicts(report, thresholds))

    report =
      Map.put(report, :passed, Enum.all?(report.thresholds, fn {_gate, passed} -> passed end))

    returned = Map.new(first_by_query, fn {id, row} -> {id, row.returned} end)
    {jsonl, sidecar} = Eval.longmemeval_export(fixture, returned)
    {:ok, report, %{jsonl: jsonl, sidecar: sidecar}}
  end

  defp seed_derived(fixture) do
    derived = Enum.filter(fixture["memories"], & &1["derived"])

    rows =
      Enum.map(derived, fn memory ->
        event_id = Ecto.UUID.generate()
        session_id = "derived-#{memory["fixture_memory_id"]}"
        subject_id = "#{fixture["fixture_id"]}:#{session_id}"
        stream_id = "#{fixture["fixture_id"]}:#{session_id}"
        now = DateTime.utc_now()

        repo().insert!(
          EventStream.changeset(%EventStream{}, %{
            stream_id: stream_id,
            project: "memory-eval-derived",
            host_id: memory["host_id"],
            client_id: memory["client_id"],
            session_id: session_id
          })
        )

        repo().insert!(%Event{
          id: event_id,
          stream_id: stream_id,
          sequence: 1,
          project: "memory-eval-derived",
          namespace: memory["namespace"],
          host_id: memory["host_id"],
          client_id: memory["client_id"],
          scope: memory["scope"],
          session_id: session_id,
          event_type: "agent.prompt.submitted",
          importance: 1,
          payload: %{},
          schema_version: 1,
          occurred_at: now,
          inserted_at: now
        })

        repo().insert!(%ProjectedSession{
          subject_id: subject_id,
          session_id: session_id,
          project: "memory-eval-derived",
          host_id: memory["host_id"],
          client_id: memory["client_id"],
          scope: memory["scope"],
          namespace: memory["namespace"],
          status: "closed",
          last_event_at: now,
          processing_version: "eval-v2",
          input_revision: memory["fixture_memory_id"]
        })

        summary =
          repo().insert!(
            Summary.changeset(%Summary{}, %{
              session_id: session_id,
              project: "memory-eval-derived",
              content: memory["content"],
              subject_id: subject_id,
              host_id: memory["host_id"],
              processing_version: "eval-v2",
              input_revision: memory["fixture_memory_id"],
              output_revision: "output-#{memory["fixture_memory_id"]}"
            })
          )

        repo().insert!(%SourceEvent{
          summary_id: summary.id,
          event_id: event_id,
          host_id: memory["host_id"],
          session_id: session_id,
          inserted_at: now
        })

        %{summary_id: summary.id, event_id: event_id, content: memory["content"]}
      end)

    {:ok, rows}
  end

  defp timed_pipeline(pipeline, fixture, query, content_ids) do
    handler = "memory-eval-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :memory, :recall, :stage],
        fn _, measurements, metadata, _ ->
          if metadata.stage in [:retrieval, :post_fusion] do
            send(parent, {:memory_eval_stage, metadata.stage, measurements.duration_us})
          end
        end,
        nil
      )

    started = System.monotonic_time()
    result = pipeline.(attrs(fixture, query), pipeline_opts())
    e2e_ms = elapsed_ms(started)
    :telemetry.detach(handler)
    stages = collect_stages(%{})

    {results, channels} =
      case result do
        {:ok, %{results: results, channels: channels}} -> {results, channels}
        _ -> {[], %{fts: %{status: :error}}}
      end

    normalized =
      Enum.flat_map(results, fn result ->
        case content_ids[result.content] do
          nil ->
            []

          id ->
            [
              %{
                fixture_id: id,
                provenance?: is_list(result.source_ids) and result.source_ids != []
              }
            ]
        end
      end)

    %{
      query_id: query["query_id"],
      returned: normalized |> Enum.map(& &1.fixture_id) |> Enum.uniq(),
      results: normalized,
      fts_available: channels.fts.status == :ok,
      retrieval_fusion_ms:
        (Map.get(stages, :retrieval, 0) + Map.get(stages, :post_fusion, 0)) / 1_000,
      e2e_ms: e2e_ms
    }
  end

  defp derived_provenance_cases(fixture, pipeline, derived) do
    Enum.map(derived, fn row ->
      query =
        fixture["partition"]
        |> Map.put("query", row.content)
        |> Map.put("project", "memory-eval-derived")
        |> Map.put("token_budget", 100_000)

      persisted? =
        not is_nil(repo().get(Event, row.event_id)) and
          repo().exists?(
            from(link in SourceEvent,
              where: link.summary_id == ^row.summary_id and link.event_id == ^row.event_id
            )
          )

      result =
        case pipeline.(query, pipeline_opts()) do
          {:ok, %{results: results}} ->
            Enum.find(results, &(&1.kind == :summary and &1.id == row.summary_id))

          _ ->
            nil
        end

      provenance? = not is_nil(result) and result.source_ids == [row.event_id]
      %{valid?: provenance? and persisted?, provenance?: provenance?, persisted?: persisted?}
    end)
  end

  defp provenance_metrics(cases) do
    valid = Enum.count(cases, & &1.valid?)

    %{
      denominator: length(cases),
      numerator: valid,
      coverage: ratio(valid, length(cases)),
      persisted: Enum.count(cases, & &1.persisted?)
    }
  end

  defp outage_cases(fixture, pipeline, samples) do
    parent = self()

    cases =
      fixture["memories"]
      |> Stream.cycle()
      |> Enum.take(samples)
      |> Enum.map(fn memory ->
        embed = fn _, _, _ ->
          send(parent, :eval_embed_failed)
          {:error, :provider_outage}
        end

        rerank = fn _, _ ->
          send(parent, :eval_reranker_failed)
          {:error, :provider_outage}
        end

        query =
          fixture["partition"]
          |> Map.put("query", memory["content"])
          |> Map.put("token_budget", 100_000)

        opts =
          pipeline_opts()
          |> Keyword.put(:retriever_opts, embed_fn: embed)
          |> Keyword.put(:reranker_opts, enabled: true, model: "eval-outage", provider: rerank)

        pipeline.(query, opts)
      end)

    embed_calls = drain(:eval_embed_failed, 0)
    reranker_calls = drain(:eval_reranker_failed, 0)

    passed =
      Enum.count(cases, fn
        {:ok, %{channels: %{fts: %{status: :ok}}, results: [_ | _]}} -> true
        _ -> false
      end)

    %{
      mode: "FTS-only; embedder and LLM unavailable",
      samples: length(cases),
      availability: ratio(passed, length(cases)),
      nonempty_fts_results: passed,
      embedding_provider_calls: embed_calls,
      reranker_provider_calls: reranker_calls
    }
  end

  defp drain(message, count) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end

  defp attrs(fixture, query) do
    fixture["partition"]
    |> Map.put("query", query["query"])
    |> Map.put("token_budget", 100_000)
  end

  defp pipeline_opts do
    [
      trace?: false,
      retriever_opts: [embed_fn: fn _, _, _ -> {:error, :provider_outage} end],
      post_fusion_opts: [limit: 5],
      reranker_opts: [enabled: false],
      packer_opts: []
    ]
  end

  defp collect_stages(acc) do
    receive do
      {:memory_eval_stage, stage, duration} -> collect_stages(Map.put(acc, stage, duration))
    after
      0 -> acc
    end
  end

  defp latency(rows, getter) do
    samples = Enum.map(rows, getter)

    %{
      samples: length(samples),
      p50_ms: Eval.percentile(samples, 50),
      p95_ms: Eval.percentile(samples, 95)
    }
  end

  defp threshold_verdicts(report, thresholds) do
    %{
      recall_any_at_5: report.quality.recall_any_at_5 >= 0.95,
      fts_outage_availability:
        report.outage.samples > 0 and report.outage.availability == 1.0 and
          report.outage.nonempty_fts_results == report.outage.samples and
          report.outage.embedding_provider_calls > 0 and report.outage.reranker_provider_calls > 0,
      derived_provenance: report.provenance.denominator > 0 and report.provenance.coverage == 1.0,
      retrieval_fusion_p95:
        report.latency.retrieval_fusion.samples >= 100 and
          report.latency.retrieval_fusion.p95_ms <
            thresholds.retrieval_fusion_p95_ms_max_exclusive,
      e2e_p95:
        report.latency.e2e.samples >= 100 and
          report.latency.e2e.p95_ms < thresholds.e2e_p95_ms_max_exclusive
    }
  end

  defp ratio(_, 0), do: 0.0
  defp ratio(value, total), do: value / total

  defp elapsed_ms(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
