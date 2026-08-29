defmodule Backplane.Memory.Recall.Store do
  @moduledoc "Transactional persistence and partition-safe reads for Recall V2 traces."

  import Ecto.Query

  alias Backplane.Memory.Config
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Recall.{Candidate, QueryPlan, Run, TraceCandidate}

  @partition_fields [:host_id, :client_id, :scope, :namespace]
  @channels ~w(fts vector graph)
  @source_types ~w(memory event observation summary request crystal lesson)
  @reranker_statuses ~w(ok disabled unavailable empty provider_error exit timeout malformed error)
  @candidate_cap 500
  @rejection_reasons ~w(diversity token_budget lifecycle duplicate below_threshold superseded disputed archived channel_error review)
  @create_options [:request_id, :correlation_id, :query_embedding_model, :reranker_model]
  @finalize_options [
    :latency_ms,
    :channel_availability,
    :channel_errors,
    :query_embedding_model,
    :reranker_model,
    :reranker_provider,
    :reranker_status,
    :reranker_error_class,
    :reranker_duration_ms
  ]
  @fail_options [:failure_class, :latency_ms, :channel_availability, :channel_errors]
  @list_options [:limit, :cursor, :status, :correlation_id, :from, :to]
  @trace_keys [
    :candidate,
    :selected,
    :rejection_reason,
    :ranks,
    :scores,
    :token_estimate,
    :pre_reranker_rank,
    :post_reranker_rank
  ]

  @doc "Whether an orchestrator should persist recall traces for this execution."
  def enabled?, do: Config.recall_trace_enabled?()

  @spec create(QueryPlan.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def create(%QueryPlan{} = plan, opts) when is_list(opts) do
    with :ok <- validate_options(opts, @create_options),
         {:ok, request_id} <- required_option(opts, :request_id),
         {:ok, correlation_id} <- required_option(opts, :correlation_id),
         {:ok, models} <- model_options(opts) do
      trace = QueryPlan.trace(plan)
      now = now()

      attrs = %{
        host_id: plan.host_id,
        client_id: plan.client_id,
        scope: plan.scope,
        namespace: plan.namespace,
        request_id: request_id,
        correlation_id: correlation_id,
        query_hash: plan.query_hash,
        normalized_query: trace["normalized_query"],
        query_plan: Map.delete(trace, "normalized_query"),
        filters: Map.take(trace, ~w(project facets temporal_hints entity_hints)),
        channel_weights: stringify_keys(plan.channel_weights),
        channel_availability: %{},
        channel_errors: %{},
        token_budget: plan.token_budget,
        status: "running",
        query_embedding_model: models.query_embedding_model,
        reranker_model: models.reranker_model,
        expires_at: DateTime.add(now, Config.recall_trace_retention_days(), :day)
      }

      case repo().insert(Run.changeset(%Run{}, attrs)) do
        {:ok, run} ->
          {:ok, run}

        {:error, changeset} ->
          if unique_request_conflict?(changeset) do
            replay_or_conflict(plan, request_id, correlation_id, attrs)
          else
            {:error, {:invalid, changeset}}
          end
      end
    end
  end

  def create(_plan, _opts), do: {:error, :invalid_query_plan}

  @spec put_candidates(Ecto.UUID.t(), map(), [map()]) ::
          {:ok, [TraceCandidate.t()]} | {:error, term()}
  def put_candidates(run_id, partition, traces) do
    transact(fn -> do_put_candidates(run_id, partition, traces) end)
  end

  @spec finalize(Ecto.UUID.t(), map(), [map()], keyword()) :: {:ok, Run.t()} | {:error, term()}
  def finalize(run_id, partition, traces, attrs) when is_list(attrs) do
    with :ok <- validate_options(attrs, @finalize_options) do
      transact(fn ->
        with {:ok, run} <- locked_run(run_id, partition),
             {:ok, partition} <- partition(partition),
             {:ok, rows} <- normalize_bounded_traces(run, partition, traces),
             {:ok, terminal_attrs} <- finalize_attrs(run, rows, attrs),
             terminal_attrs <- with_terminal_digest(terminal_attrs, rows) do
          case run.status do
            "complete" ->
              if terminal_digest_match?(run, terminal_attrs),
                do: {:ok, run},
                else: {:error, :already_finalized}

            "failed" ->
              {:error, :already_finalized}

            "running" ->
              with {:ok, _rows} <- replace_trace_rows(run.id, rows),
                   {:ok, complete} <- update_run(run, terminal_attrs) do
                {:ok, complete}
              end
          end
        end
      end)
    end
  end

  def finalize(_run_id, _partition, _traces, _attrs), do: {:error, :invalid_attributes}

  @spec fail(Ecto.UUID.t(), map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def fail(run_id, partition, attrs) when is_list(attrs) do
    with :ok <- validate_options(attrs, @fail_options) do
      transact(fn ->
        with {:ok, run} <- locked_run(run_id, partition),
             {:ok, failed_attrs} <- fail_attrs(attrs),
             failed_attrs <- with_terminal_digest(failed_attrs, []) do
          case run.status do
            "failed" ->
              if terminal_digest_match?(run, failed_attrs),
                do: {:ok, run},
                else: {:error, :already_finalized}

            "complete" ->
              {:error, :already_finalized}

            "running" ->
              update_run(run, failed_attrs)
          end
        end
      end)
    end
  end

  def fail(_run_id, _partition, _attrs), do: {:error, :invalid_attributes}

  @spec get(Ecto.UUID.t(), map()) ::
          {:ok, Run.t(), [TraceCandidate.t()]} | {:error, :not_found | :invalid_partition}
  def get(run_id, partition) do
    with {:ok, partition} <- partition(partition),
         {:ok, run_id} <- cast_uuid(run_id),
         %Run{} = run <- repo().one(partitioned_run_query(run_id, partition)) do
      candidates =
        TraceCandidate
        |> where([candidate], candidate.recall_run_id == ^run.id)
        |> order_by([candidate],
          desc: candidate.selected,
          desc_nulls_last: candidate.final_score,
          asc: candidate.id
        )
        |> limit(@candidate_cap)
        |> repo().all()

      {:ok, run, candidates}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec list(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(partition, opts \\ [])

  def list(partition, opts) when is_list(opts) do
    with :ok <- validate_options(opts, @list_options),
         {:ok, partition} <- partition(partition),
         {:ok, limit} <- list_limit(Keyword.get(opts, :limit, 50)),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)),
         {:ok, filters} <- list_filters(opts) do
      query =
        Run
        |> where(
          [run],
          run.host_id == ^partition.host_id and
            run.client_id == ^partition.client_id and
            run.scope == ^partition.scope and
            run.namespace == ^partition.namespace
        )
        |> apply_list_filters(filters)
        |> apply_cursor(cursor)
        |> order_by([run], desc: run.inserted_at, desc: run.id)
        |> limit(^(limit + 1))

      {runs, remaining} = query |> repo().all() |> Enum.split(limit)

      next_cursor =
        if remaining == [], do: nil, else: runs |> List.last() |> encode_cursor()

      {:ok, %{runs: runs, next_cursor: next_cursor}}
    end
  end

  def list(_partition, _opts), do: {:error, :invalid_options}

  defp do_put_candidates(run_id, partition, traces) do
    with {:ok, partition} <- partition(partition),
         {:ok, run} <- locked_run(run_id, partition),
         true <- run.status == "running" or {:error, :already_finalized},
         {:ok, rows} <- normalize_bounded_traces(run, partition, traces) do
      insert_trace_rows(rows)
    end
  end

  defp normalize_bounded_traces(run, partition, traces) when is_list(traces) do
    bounded = Enum.take(traces, @candidate_cap + 1)

    with true <- length(bounded) <= @candidate_cap or {:error, :too_many_candidates},
         {:ok, rows} <- normalize_traces(run, partition, bounded),
         true <- unique_candidate_rows?(rows) or {:error, :duplicate_candidates} do
      {:ok, rows}
    end
  end

  defp normalize_bounded_traces(_run, _partition, _traces), do: {:error, :invalid_candidates}

  defp normalize_traces(run, partition, traces) do
    traces
    |> Enum.reduce_while({:ok, []}, fn trace, {:ok, acc} ->
      case normalize_trace(run, partition, trace) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp normalize_trace(run, partition, %{candidate: %Candidate{} = candidate} = trace) do
    with :ok <- validate_trace_keys(trace),
         true <- candidate_partition(candidate) == partition or {:error, :partition_mismatch},
         {:ok, selected} <- boolean(Map.get(trace, :selected, false), :selected),
         {:ok, rejection_reason} <-
           rejection_reason(selected, Map.get(trace, :rejection_reason)),
         {:ok, ranks} <- ranks(Map.get(trace, :ranks, %{})),
         {:ok, scores} <- scores(Map.get(trace, :scores, %{})),
         {:ok, source_refs} <- source_refs(candidate.source_refs, candidate.source_ids),
         {:ok, pre_reranker_rank} <- optional_rank(Map.get(trace, :pre_reranker_rank)),
         {:ok, post_reranker_rank} <- optional_rank(Map.get(trace, :post_reranker_rank)),
         {:ok, token_estimate} <-
           bounded_integer(
             Map.get(trace, :token_estimate, candidate.token_estimate),
             :token_estimate,
             0,
             1_000_000
           ) do
      {:ok,
       %{
         recall_run_id: run.id,
         host_id: partition.host_id,
         client_id: partition.client_id,
         scope: partition.scope,
         namespace: partition.namespace,
         candidate_id: candidate.id,
         candidate_kind: to_string(candidate.kind),
         memory_type: to_string(candidate.memory_type),
         source_ids: candidate.source_ids,
         source_refs: source_refs,
         channel_scores: stringify_nested(candidate.channel_scores),
         fts_rank: ranks[:fts],
         vector_rank: ranks[:vector],
         graph_rank: ranks[:graph],
         fts_score: scores[:fts],
         vector_score: scores[:vector],
         graph_score: scores[:graph],
         rrf_score: scores[:rrf],
         lifecycle_score: scores[:lifecycle],
         reranker_score: scores[:reranker],
         final_score: scores[:final],
         pre_reranker_rank: pre_reranker_rank,
         post_reranker_rank: post_reranker_rank,
         selected: selected,
         rejection_reason: rejection_reason,
         token_estimate: token_estimate
       }}
    end
  end

  defp normalize_trace(_run, _partition, _trace), do: {:error, :invalid_candidate}

  defp insert_trace_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn attrs, {:ok, acc} ->
      changeset = TraceCandidate.changeset(%TraceCandidate{}, attrs)

      case repo().insert(changeset,
             on_conflict:
               {:replace,
                [
                  :source_ids,
                  :source_refs,
                  :channel_scores,
                  :fts_rank,
                  :vector_rank,
                  :graph_rank,
                  :fts_score,
                  :vector_score,
                  :graph_score,
                  :rrf_score,
                  :lifecycle_score,
                  :reranker_score,
                  :final_score,
                  :pre_reranker_rank,
                  :post_reranker_rank,
                  :selected,
                  :rejection_reason,
                  :token_estimate,
                  :updated_at
                ]},
             conflict_target: [:recall_run_id, :candidate_id, :candidate_kind],
             returning: true
           ) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, changeset} -> {:halt, {:error, {:invalid_candidate, changeset}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp replace_trace_rows(run_id, rows) do
    repo().delete_all(
      from(candidate in TraceCandidate, where: candidate.recall_run_id == ^run_id)
    )

    insert_trace_rows(rows)
  end

  defp finalize_attrs(run, rows, attrs) do
    tokens_used = rows |> Enum.filter(& &1.selected) |> Enum.sum_by(& &1.token_estimate)
    result_count = Enum.count(rows, & &1.selected)

    with true <- tokens_used <= run.token_budget or {:error, {:invalid, :token_budget}},
         {:ok, latency_ms} <- optional_nonnegative(Keyword.get(attrs, :latency_ms), :latency_ms),
         {:ok, availability} <- availability(Keyword.get(attrs, :channel_availability, %{})),
         {:ok, errors} <- errors(Keyword.get(attrs, :channel_errors, %{})),
         {:ok, embedding_model} <-
           privacy_string(
             Keyword.get(attrs, :query_embedding_model),
             :query_embedding_model,
             512
           ),
         {:ok, reranker_model} <-
           privacy_string(Keyword.get(attrs, :reranker_model), :reranker_model, 512),
         {:ok, reranker_provider} <-
           privacy_string(Keyword.get(attrs, :reranker_provider), :reranker_provider, 128),
         {:ok, reranker_status} <- reranker_status(Keyword.get(attrs, :reranker_status)),
         {:ok, reranker_error_class} <-
           privacy_string(
             Keyword.get(attrs, :reranker_error_class),
             :reranker_error_class,
             128
           ),
         {:ok, reranker_duration_ms} <-
           optional_nonnegative(
             Keyword.get(attrs, :reranker_duration_ms),
             :reranker_duration_ms
           ) do
      {:ok,
       %{
         status: "complete",
         tokens_used: tokens_used,
         result_count: result_count,
         latency_ms: latency_ms,
         channel_availability: availability,
         channel_errors: errors,
         query_embedding_model: embedding_model || run.query_embedding_model,
         reranker_model: reranker_model || run.reranker_model,
         reranker_provider: reranker_provider,
         reranker_status: reranker_status,
         reranker_error_class: reranker_error_class,
         reranker_duration_ms: reranker_duration_ms,
         failure_class: nil,
         completed_at: now()
       }}
    end
  end

  defp fail_attrs(attrs) do
    with {:ok, failure_class} <- required_option(attrs, :failure_class),
         {:ok, failure_class} <- privacy_string(failure_class, :failure_class, 512),
         {:ok, latency_ms} <- optional_nonnegative(Keyword.get(attrs, :latency_ms), :latency_ms),
         {:ok, availability} <- availability(Keyword.get(attrs, :channel_availability, %{})),
         {:ok, errors} <- errors(Keyword.get(attrs, :channel_errors, %{})) do
      {:ok,
       %{
         status: "failed",
         failure_class: failure_class,
         latency_ms: latency_ms,
         channel_availability: availability,
         channel_errors: errors,
         completed_at: now()
       }}
    end
  end

  defp update_run(run, attrs) do
    case repo().update(Run.changeset(run, attrs)) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  defp replay_or_conflict(plan, request_id, correlation_id, attrs) do
    query =
      Run
      |> where(
        [run],
        run.host_id == ^plan.host_id and run.client_id == ^plan.client_id and
          run.scope == ^plan.scope and run.namespace == ^plan.namespace and
          run.request_id == ^request_id
      )

    case repo().one(query) do
      %Run{} = existing ->
        if existing.query_hash == plan.query_hash and
             existing.query_plan == attrs.query_plan and
             existing.filters == attrs.filters and
             existing.channel_weights == attrs.channel_weights and
             existing.normalized_query == attrs.normalized_query and
             existing.correlation_id == correlation_id and
             existing.token_budget == plan.token_budget and
             existing.query_embedding_model == attrs.query_embedding_model and
             existing.reranker_model == attrs.reranker_model,
           do: {:ok, existing},
           else: {:error, :idempotency_conflict}

      nil ->
        {:error, :idempotency_conflict}
    end
  end

  defp locked_run(run_id, partition) do
    with {:ok, partition} <- partition(partition),
         {:ok, run_id} <- cast_uuid(run_id) do
      case partitioned_run_query(run_id, partition) |> lock("FOR UPDATE") |> repo().one() do
        %Run{} = run -> {:ok, run}
        nil -> {:error, :not_found}
      end
    end
  end

  defp partitioned_run_query(run_id, partition) do
    from(run in Run,
      where:
        run.id == ^run_id and run.host_id == ^partition.host_id and
          run.client_id == ^partition.client_id and run.scope == ^partition.scope and
          run.namespace == ^partition.namespace
    )
  end

  defp partition(value) when is_map(value) do
    Enum.reduce_while(@partition_fields, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.get(value, key, Map.get(value, Atom.to_string(key))) do
        item when is_binary(item) ->
          item = String.trim(item)

          if item != "" and byte_size(item) <= 512,
            do: {:cont, {:ok, Map.put(acc, key, item)}},
            else: {:halt, {:error, :invalid_partition}}

        _invalid ->
          {:halt, {:error, :invalid_partition}}
      end
    end)
  end

  defp partition(_value), do: {:error, :invalid_partition}

  defp candidate_partition(candidate), do: Map.take(candidate, @partition_fields)

  defp required_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= 512,
          do: {:ok, value},
          else: {:error, {:invalid, key}}

      _invalid ->
        {:error, {:invalid, key}}
    end
  end

  defp validate_options(opts, allowed) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      case (keys -- allowed) |> Enum.sort() do
        [] -> if(keys == Enum.uniq(keys), do: :ok, else: {:error, :invalid_options})
        unknown -> {:error, {:unknown_options, unknown}}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_trace_keys(trace) do
    case Map.keys(trace) |> Kernel.--(@trace_keys) |> Enum.sort() do
      [] -> :ok
      unknown -> {:error, {:unknown_trace_keys, unknown}}
    end
  end

  defp model_options(opts) do
    with {:ok, query_embedding_model} <-
           privacy_string(Keyword.get(opts, :query_embedding_model), :query_embedding_model, 512),
         {:ok, reranker_model} <-
           privacy_string(Keyword.get(opts, :reranker_model), :reranker_model, 512) do
      {:ok, %{query_embedding_model: query_embedding_model, reranker_model: reranker_model}}
    end
  end

  defp availability(value) when is_map(value) do
    if Enum.all?(value, fn {key, available} ->
         to_string(key) in @channels and is_boolean(available)
       end),
       do: {:ok, stringify_keys(value)},
       else: {:error, {:invalid, :channel_availability}}
  end

  defp availability(_value), do: {:error, {:invalid, :channel_availability}}

  defp errors(value) when is_map(value) do
    if Enum.all?(value, fn {key, error} ->
         to_string(key) in @channels and is_binary(error) and byte_size(error) <= 1_024
       end) do
      {:ok, filtered} = Filter.apply_payload(stringify_keys(value))
      {:ok, filtered}
    else
      {:error, {:invalid, :channel_errors}}
    end
  end

  defp errors(_value), do: {:error, {:invalid, :channel_errors}}

  defp ranks(value) when is_map(value) do
    normalized = atomize_score_keys(value, [:fts, :vector, :graph])

    if normalized != :error and
         Enum.all?(normalized, fn {_key, rank} -> is_integer(rank) and rank > 0 end),
       do: {:ok, normalized},
       else: {:error, {:invalid, :ranks}}
  end

  defp ranks(_value), do: {:error, {:invalid, :ranks}}

  defp scores(value) when is_map(value) do
    allowed = [:fts, :vector, :graph, :rrf, :lifecycle, :reranker, :final]
    normalized = atomize_score_keys(value, allowed)

    if normalized != :error and Enum.all?(normalized, fn {_key, score} -> is_number(score) end),
      do: {:ok, normalized},
      else: {:error, {:invalid, :scores}}
  end

  defp scores(_value), do: {:error, {:invalid, :scores}}

  defp source_refs([], _source_ids), do: {:error, {:invalid, :source_refs}}

  defp source_refs(refs, source_ids) when is_list(refs) and length(refs) <= 256 do
    normalized =
      Enum.reduce_while(refs, [], fn
        ref, acc when is_map(ref) ->
          type = Map.get(ref, :type, Map.get(ref, "type")) |> to_string()
          id = Map.get(ref, :id, Map.get(ref, "id"))

          case Ecto.UUID.cast(id) do
            {:ok, uuid} when type in @source_types ->
              {:cont, [%{"type" => type, "id" => uuid} | acc]}

            _invalid ->
              {:halt, :error}
          end

        _invalid, _acc ->
          {:halt, :error}
      end)

    case normalized do
      :error ->
        {:error, {:invalid, :source_refs}}

      reversed ->
        refs = reversed |> Enum.reverse() |> Enum.uniq()
        ids = refs |> Enum.map(& &1["id"]) |> Enum.uniq()

        if ids == source_ids,
          do: {:ok, %{"refs" => refs}},
          else: {:error, {:invalid, :source_refs}}
    end
  end

  defp source_refs(_refs, _source_ids), do: {:error, {:invalid, :source_refs}}

  defp optional_rank(nil), do: {:ok, nil}
  defp optional_rank(value), do: bounded_integer(value, :reranker_rank, 1, 500)

  defp atomize_score_keys(value, allowed) do
    Enum.reduce_while(value, %{}, fn {key, item}, acc ->
      atom = if key in allowed, do: key, else: Enum.find(allowed, &(Atom.to_string(&1) == key))
      if atom, do: {:cont, Map.put(acc, atom, item)}, else: {:halt, :error}
    end)
  end

  defp boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, key), do: {:error, {:invalid, key}}

  defp bounded_integer(value, _key, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: {:ok, value}

  defp bounded_integer(_value, key, _minimum, _maximum), do: {:error, {:invalid, key}}

  defp optional_nonnegative(nil, _key), do: {:ok, nil}
  defp optional_nonnegative(value, key), do: bounded_integer(value, key, 0, 2_147_483_647)

  defp optional_string(nil, _key, _max), do: {:ok, nil}

  defp optional_string(value, key, max) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and byte_size(value) <= max,
      do: {:ok, if(value == "", do: nil, else: value)},
      else: {:error, {:invalid, key}}
  end

  defp optional_string(_value, key, _max), do: {:error, {:invalid, key}}

  defp list_limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp list_limit(_value), do: {:error, {:invalid, :limit}}

  defp list_filters(opts) do
    with {:ok, status} <- list_status(Keyword.get(opts, :status)),
         {:ok, correlation_id} <-
           list_correlation_id(Keyword.get(opts, :correlation_id)),
         {:ok, from} <- utc_datetime(Keyword.get(opts, :from), :from),
         {:ok, to} <- utc_datetime(Keyword.get(opts, :to), :to),
         true <- is_nil(from) or is_nil(to) or DateTime.compare(from, to) != :gt do
      {:ok, %{status: status, correlation_id: correlation_id, from: from, to: to}}
    else
      false -> {:error, {:invalid, :time_range}}
      {:error, _reason} = error -> error
    end
  end

  defp list_status(nil), do: {:ok, nil}
  defp list_status(status) when status in ~w(running complete failed), do: {:ok, status}
  defp list_status(_status), do: {:error, {:invalid, :status}}

  defp list_correlation_id(nil), do: {:ok, nil}

  defp list_correlation_id(value) do
    case optional_string(value, :correlation_id, 512) do
      {:ok, nil} -> {:error, {:invalid, :correlation_id}}
      {:ok, correlation_id} -> {:ok, correlation_id}
      {:error, _reason} = error -> error
    end
  end

  defp utc_datetime(nil, _key), do: {:ok, nil}
  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value, _key), do: {:ok, value}
  defp utc_datetime(_value, key), do: {:error, {:invalid, key}}

  defp apply_list_filters(query, filters) do
    query
    |> maybe_where(:status, filters.status)
    |> maybe_where(:correlation_id, filters.correlation_id)
    |> maybe_from(filters.from)
    |> maybe_to(filters.to)
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, :status, value), do: where(query, [run], run.status == ^value)

  defp maybe_where(query, :correlation_id, value),
    do: where(query, [run], run.correlation_id == ^value)

  defp maybe_from(query, nil), do: query
  defp maybe_from(query, value), do: where(query, [run], run.inserted_at >= ^value)
  defp maybe_to(query, nil), do: query
  defp maybe_to(query, value), do: where(query, [run], run.inserted_at <= ^value)

  defp reranker_status(nil), do: {:ok, nil}

  defp reranker_status(status) when is_atom(status),
    do: reranker_status(Atom.to_string(status))

  defp reranker_status(status) when status in @reranker_statuses, do: {:ok, status}
  defp reranker_status(_status), do: {:error, {:invalid, :reranker_status}}

  defp encode_cursor(%Run{} = run) do
    [DateTime.to_iso8601(run.inserted_at), run.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(value) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [timestamp, id]} <- Jason.decode(json),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_value), do: {:error, :invalid_cursor}
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {inserted_at, id}) do
    where(
      query,
      [run],
      run.inserted_at < ^inserted_at or (run.inserted_at == ^inserted_at and run.id < ^id)
    )
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp terminal_digest_match?(run, attrs), do: run.terminal_digest == attrs.terminal_digest

  defp with_terminal_digest(attrs, rows) do
    digest_attrs = Map.drop(attrs, [:completed_at, :terminal_digest])

    canonical_rows =
      rows
      |> Enum.map(&Map.drop(&1, [:inserted_at, :updated_at]))
      |> Enum.sort_by(&{&1.candidate_kind, &1.candidate_id})

    digest =
      {digest_attrs, canonical_rows}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))

    Map.put(attrs, :terminal_digest, digest)
  end

  defp unique_candidate_rows?(rows) do
    identities = Enum.map(rows, &{&1.candidate_id, &1.candidate_kind})
    length(identities) == MapSet.size(MapSet.new(identities))
  end

  defp rejection_reason(true, nil), do: {:ok, nil}
  defp rejection_reason(true, _reason), do: {:error, {:invalid, :rejection_reason}}

  defp rejection_reason(false, reason) when is_binary(reason) do
    reason = String.trim(reason)

    if reason in @rejection_reasons,
      do: {:ok, reason},
      else: {:error, {:invalid, :rejection_reason}}
  end

  defp rejection_reason(false, _reason), do: {:error, {:invalid, :rejection_reason}}

  defp privacy_string(value, key, max) do
    with {:ok, value} <- optional_string(value, key, max),
         {:ok, filtered} <- Filter.apply_payload(%{"value" => value}) do
      {:ok, filtered["value"]}
    end
  end

  defp unique_request_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, metadata}} ->
        metadata[:constraint_name] == "memory_recall_runs_partition_request_uniq"
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_nested(map) do
    Map.new(map, fn {key, value} ->
      nested = if is_map(value), do: stringify_keys(value), else: value
      {to_string(key), nested}
    end)
  end

  defp transact(fun) do
    case repo().transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> repo().rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
