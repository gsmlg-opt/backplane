defmodule Backplane.Memory.Recall.Pipeline do
  @moduledoc "End-to-end Recall V2 orchestration with guarded tracing and telemetry."

  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Recall.{Packer, PostFusion, QueryPlan, Reranker, Retriever, Run, Store}

  @options [
    :request_id,
    :correlation_id,
    :query_embedding_model,
    :trace?,
    :retriever_opts,
    :post_fusion_opts,
    :reranker_opts,
    :packer_opts
  ]
  @event [:backplane, :memory, :recall, :stage]

  def run(attrs, opts \\ [])

  def run(attrs, opts) when is_map(attrs) and not is_struct(attrs) and is_list(opts) do
    with :ok <- validate_options(opts),
         {result, duration} <- timed(fn -> QueryPlan.new(attrs) end),
         {:ok, plan} <- emit_result(:query_plan, result, duration, nil) do
      execute(plan, opts)
    end
  end

  def run(_attrs, _opts), do: {:error, :invalid_recall_input}

  defp execute(plan, opts) do
    started = System.monotonic_time()
    partition = partition(plan)

    case create_trace(plan, opts) do
      {:ok, nil} ->
        run_stages(plan, opts, nil, started, partition)

      {:ok, %Run{status: "running"} = run} ->
        run_stages(plan, opts, run, started, partition)

      {:ok, %Run{status: "complete"} = run} ->
        replay_complete(run, partition, started)

      {:ok, %Run{status: "failed"} = run} ->
        replay_failed(run, partition, started)

      {:error, reason} ->
        error = stage_error(reason)
        emit(:pipeline, elapsed_us(started), 0, :error, partition, %{error_class: error})
        {:error, error}
    end
  end

  defp run_stages(plan, opts, run, started, partition) do
    with {retrieval_result, retrieval_us} <-
           timed(fn -> Retriever.retrieve(plan, Keyword.get(opts, :retriever_opts, [])) end),
         {:ok, retrieval} <-
           emit_retrieval(retrieval_result, retrieval_us, partition),
         {post_result, post_us} <-
           timed(fn ->
             PostFusion.apply(retrieval.fused, Keyword.get(opts, :post_fusion_opts, []))
           end),
         {:ok, post_fusion} <-
           emit_result(:post_fusion, post_result, post_us, partition),
         {rerank_result, rerank_us} <-
           timed(fn ->
             Reranker.apply(
               post_fusion,
               plan.normalized_query,
               Keyword.get(opts, :reranker_opts, [])
             )
           end),
         {:ok, reranked, reranker_meta} <-
           emit_reranker(rerank_result, rerank_us, partition, opts),
         ranked <- add_reranker_ranks(post_fusion, reranked),
         {pack_result, pack_us} <-
           timed(fn ->
             Packer.pack(ranked, plan.token_budget, Keyword.get(opts, :packer_opts, []))
           end),
         {:ok, packed, budget_meta} <-
           emit_packer(pack_result, pack_us, partition),
         :ok <- validate_selected_provenance(packed, not is_nil(run)),
         {:ok, completed_run} <-
           finalize_trace(
             run,
             partition,
             packed,
             retrieval,
             Map.put(reranker_meta, :duration_ms, div(rerank_us, 1_000)),
             opts,
             started
           ) do
      results = packed |> Enum.filter(& &1.selected) |> Enum.map(&normalize_result/1)
      duration_us = elapsed_us(started)

      emit(:pipeline, duration_us, length(results), :ok, partition, %{
        token_budget: plan.token_budget,
        used_tokens: budget_meta.used_tokens,
        reranker_status: reranker_meta.status,
        reranker_model: safe_model(reranker_meta.model),
        reranker_provider: provider_label(opts, reranker_meta.status)
      })

      {:ok,
       %{
         status: :ok,
         recall_run_id: if(completed_run, do: completed_run.id, else: nil),
         results: results,
         channels: public_channels(retrieval.channels),
         token_budget: plan.token_budget,
         used_tokens: budget_meta.used_tokens
       }}
    else
      {:error, reason} ->
        error = stage_error(reason)
        fail_trace(run, partition, error, started)
        emit(:pipeline, elapsed_us(started), 0, :error, partition, %{error_class: error})
        {:error, error}
    end
  end

  defp create_trace(plan, opts) do
    if Keyword.get(opts, :trace?, Store.enabled?()) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
      correlation_id = Keyword.get(opts, :correlation_id, Ecto.UUID.generate())
      reranker_model = opts |> Keyword.get(:reranker_opts, []) |> Keyword.get(:model)
      reranker_model = reranker_model || configured_reranker_model()

      case Store.create(plan,
             request_id: request_id,
             correlation_id: correlation_id,
             query_embedding_model: configured_embedding_model(opts),
             reranker_model: reranker_model
           ) do
        {:ok, run} ->
          {:ok, run}

        {:error, _reason} ->
          {:error, :trace_create_failed}
      end
    else
      {:ok, nil}
    end
  end

  defp finalize_trace(nil, _partition, _packed, _retrieval, _reranker, _opts, _started),
    do: {:ok, nil}

  defp finalize_trace(run, partition, packed, retrieval, reranker, opts, started) do
    attrs = [
      latency_ms: div(elapsed_us(started), 1_000),
      channel_availability: retrieval.trace.channel_availability,
      channel_errors: retrieval.trace.channel_errors,
      reranker_model: reranker.model,
      reranker_provider: provider_label(opts, reranker.status),
      reranker_status: reranker.status,
      reranker_error_class: reranker_error_class(reranker.status),
      reranker_duration_ms: reranker.duration_ms
    ]

    case Store.finalize(run.id, partition, packed, attrs) do
      {:ok, completed} ->
        {:ok, completed}

      {:error, _reason} ->
        {:error, :trace_finalize_failed}
    end
  end

  defp fail_trace(nil, _partition, _error, _started), do: :ok

  defp fail_trace(run, partition, error, started) do
    _result =
      Store.fail(run.id, partition,
        failure_class: Atom.to_string(error),
        latency_ms: div(elapsed_us(started), 1_000)
      )

    :ok
  end

  defp validate_options(opts) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []
    unknown = keys -- @options

    trace = if Keyword.keyword?(opts), do: Keyword.get(opts, :trace?, Store.enabled?()), else: nil

    with true <- Keyword.keyword?(opts),
         true <- keys == Enum.uniq(keys) and unknown == [],
         true <- is_boolean(trace),
         true <- valid_id?(opts[:request_id]) and valid_id?(opts[:correlation_id]),
         true <- valid_model_option?(opts[:query_embedding_model]),
         :ok <- Retriever.validate_options(Keyword.get(opts, :retriever_opts, [])),
         :ok <- PostFusion.validate_options(Keyword.get(opts, :post_fusion_opts, [])),
         :ok <- Reranker.validate_options(Keyword.get(opts, :reranker_opts, [])),
         :ok <- Packer.validate_options(Keyword.get(opts, :packer_opts, [])) do
      :ok
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp valid_id?(nil), do: true
  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..512
  defp valid_model_option?(nil), do: true

  defp valid_model_option?(value),
    do: is_binary(value) and byte_size(String.trim(value)) in 1..512

  defp emit_result(stage, {:ok, value}, duration, partition) do
    count = if is_list(value), do: length(value), else: 1
    emit(stage, duration, count, :ok, partition, %{})
    {:ok, value}
  end

  defp emit_result(:query_plan, {:error, reason}, duration, nil) do
    emit(:query_plan, duration, 0, :error, nil, %{error_class: :query_plan_failed})
    {:error, reason}
  end

  defp emit_result(stage, {:error, _reason}, duration, partition) do
    error = stage_error(stage)
    emit(stage, duration, 0, :error, partition, %{error_class: error})
    {:error, error}
  end

  defp emit_retrieval({:ok, retrieval}, duration, partition) do
    statuses = Map.new(retrieval.channels, fn {channel, value} -> {channel, value.status} end)
    timings = Map.new(retrieval.channels, fn {channel, value} -> {channel, value.duration_us} end)

    errors =
      Map.new(retrieval.channels, fn {channel, value} ->
        {channel, value.error || "none"}
      end)

    emit(:retrieval, duration, length(retrieval.fused), :ok, partition, %{
      channel_statuses: statuses,
      channel_timings_us: timings,
      channel_error_classes: errors
    })

    {:ok, retrieval}
  end

  defp emit_retrieval({:error, _reason}, duration, partition) do
    emit(:retrieval, duration, 0, :error, partition, %{error_class: :retrieval_failed})
    {:error, :retrieval_failed}
  end

  defp emit_reranker({:ok, traces, meta}, duration, partition, opts) do
    emit(:reranker, duration, Enum.count(traces, & &1.selected), meta.status, partition, %{
      reranker_status: meta.status,
      reranker_model: safe_model(meta.model),
      reranker_provider: provider_label(opts, meta.status),
      error_class: reranker_error_class(meta.status),
      optional_llm: true
    })

    {:ok, traces, meta}
  end

  defp emit_reranker({:error, _reason}, duration, partition, opts) do
    emit(:reranker, duration, 0, :error, partition, %{
      error_class: :reranker_failed,
      reranker_provider: provider_label(opts, :error),
      optional_llm: true
    })

    {:error, :reranker_failed}
  end

  defp emit_packer({:ok, traces, meta}, duration, partition) do
    emit(:packer, duration, Enum.count(traces, & &1.selected), :ok, partition, %{
      token_budget: meta.token_budget,
      used_tokens: meta.used_tokens
    })

    {:ok, traces, meta}
  end

  defp emit_packer({:error, _reason}, duration, partition) do
    emit(:packer, duration, 0, :error, partition, %{error_class: :packing_failed})
    {:error, :packing_failed}
  end

  defp validate_selected_provenance(traces, typed_required?) do
    valid =
      traces
      |> Enum.filter(& &1.selected)
      |> Enum.all?(fn trace ->
        trace.candidate.source_ids != [] and
          Enum.all?(trace.candidate.source_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
          (not typed_required? or trace.candidate.source_refs != [])
      end)

    if valid, do: :ok, else: {:error, :provenance_failed}
  end

  defp add_reranker_ranks(before_traces, after_traces) do
    pre = rank_by_identity(before_traces)
    post = rank_by_identity(after_traces)

    Enum.map(after_traces, fn trace ->
      identity = {trace.candidate.kind, trace.candidate.id}

      trace
      |> Map.put(:pre_reranker_rank, Map.fetch!(pre, identity))
      |> Map.put(:post_reranker_rank, Map.fetch!(post, identity))
    end)
  end

  defp rank_by_identity(traces) do
    traces
    |> Enum.with_index(1)
    |> Map.new(fn {trace, rank} -> {{trace.candidate.kind, trace.candidate.id}, rank} end)
  end

  defp normalize_result(trace) do
    candidate = trace.candidate

    %{
      id: candidate.id,
      kind: candidate.kind,
      memory_type: candidate.memory_type,
      content: candidate.content,
      final_score: trace.scores.final,
      score_breakdown: trace.scores,
      source_ids: candidate.source_ids,
      confidence: candidate.confidence,
      lifecycle_state: candidate.lifecycle_state,
      token_estimate: trace.token_estimate
    }
  end

  defp public_channels(channels) do
    Map.new(channels, fn {channel, outcome} ->
      {channel,
       %{
         status: outcome.status,
         count: length(outcome.candidates),
         duration_us: outcome.duration_us
       }}
    end)
  end

  defp emit(stage, duration, count, status, partition, extra) do
    metadata =
      %{stage: stage, status: status}
      |> Map.merge(if(partition, do: partition, else: %{}))
      |> Map.merge(extra)

    :telemetry.execute(@event, %{duration_us: duration, count: count}, metadata)
  end

  defp safe_model(nil), do: nil

  defp safe_model(model) do
    {:ok, safe} = Filter.apply_bounded(model, 512)
    safe
  end

  defp provider_label(opts) do
    if Keyword.has_key?(Keyword.get(opts, :reranker_opts, []), :provider),
      do: "injected",
      else: configured_provider_label()
  end

  defp provider_label(_opts, status) when status in [:disabled, :unavailable, :empty],
    do: "none"

  defp provider_label(opts, _status), do: provider_label(opts)

  defp configured_provider_label do
    case Application.get_env(:backplane_memory, :llm_proxy_provider_label, "backplane_llm_proxy") do
      label when is_binary(label) ->
        {:ok, safe} = Filter.apply_bounded(String.trim(label), 128)
        if safe == "", do: "backplane_llm_proxy", else: safe

      _invalid ->
        "backplane_llm_proxy"
    end
  end

  defp configured_reranker_model do
    case Backplane.Settings.get("memory.llm_model") do
      model when is_binary(model) -> nonblank_model(model)
      _other -> nil
    end
  end

  defp configured_embedding_model(opts) do
    case Keyword.get(opts, :query_embedding_model) ||
           Application.get_env(:backplane_memory, :embed_model) do
      model when is_binary(model) -> nonblank_model(model)
      _other -> nil
    end
  end

  defp nonblank_model(model) do
    case String.trim(model) do
      "" -> nil
      value -> value
    end
  end

  defp reranker_error_class(:ok), do: "none"
  defp reranker_error_class(:disabled), do: "disabled"
  defp reranker_error_class(:unavailable), do: "unavailable"
  defp reranker_error_class(:empty), do: "empty"
  defp reranker_error_class(:provider_error), do: "provider_error"
  defp reranker_error_class(:exit), do: "provider_exit"
  defp reranker_error_class(:timeout), do: "timeout"
  defp reranker_error_class(:malformed), do: "malformed_response"
  defp reranker_error_class(_unknown), do: "reranker_error"

  defp replay_complete(run, partition, started) do
    emit(:pipeline, elapsed_us(started), 0, :already_complete, partition, %{
      error_class: "none",
      recall_run_id: run.id
    })

    {:error, :recall_already_complete}
  end

  defp replay_failed(run, partition, started) do
    emit(:pipeline, elapsed_us(started), 0, :already_failed, partition, %{
      error_class: "already_failed",
      recall_run_id: run.id
    })

    {:error, :recall_already_failed}
  end

  defp stage_error(reason)
       when reason in [
              :query_plan_failed,
              :retrieval_failed,
              :post_fusion_failed,
              :reranker_failed,
              :packing_failed,
              :provenance_failed,
              :trace_create_failed,
              :trace_finalize_failed
            ],
       do: reason

  defp stage_error(:query_plan), do: :query_plan_failed
  defp stage_error(:post_fusion), do: :post_fusion_failed
  defp stage_error(_private), do: :pipeline_failed

  defp partition(plan) do
    %{
      host_id: plan.host_id,
      client_id: plan.client_id,
      scope: plan.scope,
      namespace: plan.namespace,
      project: plan.project
    }
  end

  defp timed(fun) do
    started = System.monotonic_time()
    {fun.(), elapsed_us(started)}
  end

  defp elapsed_us(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
  end
end
