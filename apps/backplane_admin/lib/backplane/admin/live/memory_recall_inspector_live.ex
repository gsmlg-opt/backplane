defmodule Backplane.Admin.MemoryRecallInspectorLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Recall.Store

  @partition_params ~w(host client scope namespace)
  @candidate_kinds ~w(memory lesson crystal summary observation)
  @candidate_page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/recall",
       partition_params: @partition_params,
       candidate_kinds: @candidate_kinds,
       partition: nil,
       query: %{},
       filters: %{},
       page: %{runs: [], next_cursor: nil},
       run: nil,
       candidates: [],
       candidate_filters: %{"selection" => "all"},
       candidate_next_cursor: nil,
       query_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case partition(params) do
      {:ok, partition} -> load(socket, params, partition)
      {:error, :invalid_partition} -> {:noreply, assign(socket, partition: nil)}
    end
  end

  defp load(%{assigns: %{live_action: :index}} = socket, params, partition) do
    {query, options, invalid?} = normalize_list_params(params, partition)
    result = safe_store(fn -> Store.list(partition, options) end)

    case result do
      {:ok, page} ->
        socket =
          assign(socket,
            partition: partition,
            query: query,
            filters: Map.drop(query, @partition_params),
            page: page,
            query_error: nil
          )

        {:noreply, canonicalize(socket, params, query, invalid?)}

      {:error, :invalid_cursor} ->
        query = Map.delete(query, "cursor")

        {:noreply,
         socket
         |> put_flash(:error, "One invalid recall parameter was removed.")
         |> push_patch(to: index_path(query), replace: true)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           partition: partition,
           page: %{runs: [], next_cursor: nil},
           query_error: reason
         )}
    end
  end

  defp load(%{assigns: %{live_action: :show}} = socket, params, partition) do
    case safe_store(fn -> Store.get(params["recall_run_id"], partition) end) do
      {:ok, run, candidates} ->
        {filters, invalid?} = normalize_candidate_filters(params)
        list_params = Map.drop(params, ["recall_run_id", "selection", "kind", "candidate_cursor"])
        {list_query, _options, invalid_list?} = normalize_list_params(list_params, partition)
        {page, next_cursor} = candidate_page(candidates, filters)
        query = Map.merge(list_query, filters)

        socket =
          assign(socket,
            partition: partition,
            query: query,
            run: run,
            candidates: page,
            candidate_filters: filters,
            candidate_next_cursor: next_cursor,
            query_error: nil
          )

        {:noreply,
         if(invalid? or invalid_list?,
           do:
             socket
             |> put_flash(:error, "One invalid candidate parameter was removed.")
             |> push_patch(to: detail_path(run.id, query), replace: true),
           else: socket
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           partition: partition,
           run: nil,
           candidates: [],
           candidate_next_cursor: nil,
           query_error: reason
         )}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => raw}, socket) do
    query =
      raw
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_unused_") end)
      |> Map.drop(["cursor"])
      |> Map.merge(canonical_partition(socket.assigns.partition))

    {:noreply, push_patch(socket, to: index_path(query), replace: true)}
  end

  def handle_event("candidate_filter", %{"candidate_filters" => raw}, socket) do
    query =
      socket.assigns.query
      |> Map.drop(["selection", "kind", "candidate_cursor"])
      |> Map.merge(raw)
      |> Map.drop(["candidate_cursor"])
      |> Map.merge(canonical_partition(socket.assigns.partition))

    {:noreply, push_patch(socket, to: detail_path(socket.assigns.run.id, query), replace: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-recall-inspector">
      <.memory_page_header title="Recall Inspector" subtitle="Partition-safe Recall V2 execution traces" />

      <.dm_card :if={is_nil(@partition)} id="recall-partition-empty" variant="bordered" padding="lg">
        <h2 class="text-lg font-semibold">Select an exact memory partition</h2>
        <p class="mt-2 text-sm text-on-surface-variant">
          Supply host, client, scope, and namespace in the URL to inspect recall traces.
        </p>
        <form method="get" action="/memory/recall" class="mt-4 grid gap-3 sm:grid-cols-2">
          <fieldset class="contents">
            <legend class="sr-only">Exact memory partition</legend>
            <label :for={field <- @partition_params} class="text-sm font-medium">
              {String.capitalize(field)}
              <input name={field} class="input mt-1 w-full" required maxlength="512" />
            </label>
          </fieldset>
          <button class="btn btn-primary" type="submit">Inspect partition</button>
        </form>
      </.dm_card>

      <.dm_alert :if={@query_error} id="recall-query-error" variant="error" title="Recall unavailable" compact>
        Memory data is unavailable. Retry after checking the database connection.
      </.dm_alert>

      <section :if={@partition && @live_action == :index} aria-labelledby="recall-runs-heading">
        <h2 id="recall-runs-heading" class="text-lg font-semibold">Recall runs</h2>
        <.form id="recall-filters" for={%{}} as={:filters} phx-submit="filter" class="my-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <input type="hidden" name="filters[cursor]" value={@filters["cursor"]} />
          <label class="text-sm font-medium">Status
            <select name="filters[status]" class="select mt-1 w-full">
              <option value="" selected={is_nil(@filters["status"])}>All statuses</option>
              <option :for={status <- ~w(running complete failed)} value={status} selected={@filters["status"] == status}>{status}</option>
            </select>
          </label>
          <label class="text-sm font-medium">Correlation ID
            <input name="filters[correlation_id]" value={@filters["correlation_id"]} class="input mt-1 w-full" />
          </label>
          <label class="text-sm font-medium">From
            <input name="filters[from]" value={@filters["from"]} class="input mt-1 w-full" />
          </label>
          <label class="text-sm font-medium">To
            <input name="filters[to]" value={@filters["to"]} class="input mt-1 w-full" />
          </label>
          <button type="submit" class="btn btn-primary">Apply filters</button>
        </.form>
        <.dm_card :if={is_nil(@query_error) && @page.runs == []} id="recall-no-runs" variant="bordered" padding="lg">
          No matching recall runs.
        </.dm_card>
        <div :for={run <- @page.runs} id={"recall-run-#{run.id}"} class="mt-3 rounded-lg bg-surface-container p-4 text-on-surface">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div><.status_badge status={run.status} /> {format_datetime(run.inserted_at)}</div>
            <.link navigate={detail_path(run.id, @query)} class="text-primary underline underline-offset-4">View details</.link>
          </div>
          <p class="mt-2">{run.normalized_query || "Query unavailable"}</p>
          <p class="text-sm text-on-surface-variant">Correlation: {run.correlation_id}</p>
          <p class="text-sm">Results {run.result_count}; tokens {run.tokens_used}/{run.token_budget}; latency {run.latency_ms || "—"} ms</p>
          <p class="text-sm">Channels: {channel_summary(run)}</p>
        </div>
        <.memory_link_button :if={@page.next_cursor} id="recall-next-page" patch={index_path(Map.put(@query, "cursor", @page.next_cursor))}>
          Older runs
        </.memory_link_button>
      </section>

      <section :if={@partition && @live_action == :show && @run} id="recall-run-detail" aria-labelledby="recall-detail-heading">
        <h2 id="recall-detail-heading" class="text-lg font-semibold">Run detail</h2>
        <dl class="mt-3 grid gap-3 sm:grid-cols-2">
          <.identity_value label="Run ID" value={@run.id} />
          <.identity_value label="Request" value={@run.request_id} />
          <.identity_value label="Correlation" value={@run.correlation_id} />
          <.identity_value label="Status" value={@run.status} />
          <.identity_value label="Failure class" value={@run.failure_class} />
          <.identity_value label="Host" value={@run.host_id} />
          <.identity_value label="Client" value={@run.client_id} />
          <.identity_value label="Scope" value={@run.scope} />
          <.identity_value label="Namespace" value={@run.namespace} />
          <.identity_value label="Normalized query" value={@run.normalized_query} />
          <.identity_value label="Query hash" value={Base.encode16(@run.query_hash || <<>>, case: :lower)} />
          <.identity_value label="Embedding model" value={@run.query_embedding_model} />
          <.identity_value label="Reranker" value={@run.reranker_provider} />
          <.identity_value label="Reranker model" value={@run.reranker_model} />
          <.identity_value label="Reranker status" value={@run.reranker_status} />
          <.identity_value label="Reranker error" value={@run.reranker_error_class} />
          <.identity_value label="Reranker duration" value={duration(@run.reranker_duration_ms)} />
          <.identity_value label="Latency" value={duration(@run.latency_ms)} />
          <.identity_value label="Created" value={format_datetime(@run.inserted_at)} />
          <.identity_value label="Completed" value={format_datetime(@run.completed_at)} />
          <.identity_value label="Expires" value={format_datetime(@run.expires_at)} />
        </dl>
        <section class="mt-6" aria-labelledby="recall-budget-heading">
          <h3 id="recall-budget-heading" class="text-lg font-semibold">Token budget</h3>
          <progress aria-label="Recall token budget used" class="progress w-full" value={@run.tokens_used} max={@run.token_budget}>{@run.tokens_used}/{@run.token_budget}</progress>
          <p>{@run.tokens_used} / {@run.token_budget} tokens used across {@run.result_count} selected results.</p>
        </section>
        <section class="mt-6" aria-labelledby="recall-plan-heading">
          <h3 id="recall-plan-heading" class="text-lg font-semibold">Resolved plan and channel evidence</h3>
          <pre class="mt-2 overflow-auto rounded bg-surface-container p-3 text-xs">{format_json(%{query_plan: @run.query_plan, filters: @run.filters, channel_weights: @run.channel_weights, channel_availability: @run.channel_availability, channel_errors: @run.channel_errors})}</pre>
        </section>
        <section class="mt-6" aria-labelledby="recall-candidates-heading">
          <h3 id="recall-candidates-heading" class="text-lg font-semibold">Candidates</h3>
          <form id="candidate-filters" phx-submit="candidate_filter" class="my-3 flex flex-wrap gap-3">
            <fieldset class="contents">
              <legend class="sr-only">Candidate result filters</legend>
              <label>Selection
                <select name="candidate_filters[selection]" class="select">
                  <option :for={selection <- ~w(all selected rejected)} value={selection} selected={@candidate_filters["selection"] == selection}>{selection}</option>
                </select>
              </label>
              <label>Kind
                <select name="candidate_filters[kind]" class="select">
                  <option value="">All kinds</option>
                  <option :for={kind <- @candidate_kinds} value={kind} selected={@candidate_filters["kind"] == kind}>{kind}</option>
                </select>
              </label>
            </fieldset>
            <button type="submit" class="btn btn-primary">Filter candidates</button>
          </form>
          <p :if={@candidates == []} id="recall-no-candidates">No candidates recorded for this run.</p>
          <div class="overflow-x-auto">
            <table id="recall-candidates-table" class="table" phx-mounted={fix_dm_table_rowgroup_roles("recall-candidates-table")}>
              <thead><tr><th>Candidate</th><th>Decision</th><th>Scores</th><th>Rank movement</th><th>Budget</th><th>Provenance</th></tr></thead>
              <tbody>
                <tr :for={candidate <- @candidates} id={"recall-candidate-#{candidate.id}"}>
                  <td>{candidate.candidate_kind} / {candidate.memory_type}<br/><span class="font-mono text-xs">{candidate.candidate_id}</span></td>
                  <td>{if candidate.selected, do: "Selected", else: "Rejected"}<br/><span>{rejection_explanation(candidate.rejection_reason)}</span></td>
                  <td class="font-mono text-xs">fts={score(candidate.fts_score)} (rank {rank(candidate.fts_rank)}) vector={score(candidate.vector_score)} (rank {rank(candidate.vector_rank)}) graph={score(candidate.graph_score)} (rank {rank(candidate.graph_rank)}) rrf={score(candidate.rrf_score)} lifecycle={score(candidate.lifecycle_score)} reranker={score(candidate.reranker_score)} final={score(candidate.final_score)}</td>
                  <td>Pre-reranker {rank(candidate.pre_reranker_rank)}; post-reranker {rank(candidate.post_reranker_rank)}. Rank movement: {rank_movement(candidate)}</td>
                  <td>{candidate.token_estimate} tokens {if candidate.selected, do: "(contributes)", else: "(excluded)"}</td>
                  <td>
                    <span :if={source_refs(candidate) == []}>Provenance unavailable (legacy trace)</span>
                    <ul :if={source_refs(candidate) != []} aria-label="Typed provenance"><li :for={ref <- source_refs(candidate)} class="font-mono text-xs">{ref["type"]}: {ref["id"]}</li></ul>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.memory_link_button :if={@candidate_next_cursor} id="candidate-next-page" patch={detail_path(@run.id, Map.put(@query, "candidate_cursor", @candidate_next_cursor))}>More candidates</.memory_link_button>
        </section>
      </section>
    </div>
    """
  end

  defp partition(params) do
    values = Enum.map(@partition_params, &{&1, params[&1]})

    if Enum.all?(values, fn {_key, value} ->
         is_binary(value) and String.trim(value) != "" and byte_size(String.trim(value)) <= 512
       end) do
      {:ok,
       %{
         host_id: String.trim(params["host"]),
         client_id: String.trim(params["client"]),
         scope: String.trim(params["scope"]),
         namespace: String.trim(params["namespace"])
       }}
    else
      {:error, :invalid_partition}
    end
  end

  defp safe_store(fun) do
    fun.()
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp normalize_list_params(params, partition) do
    base = canonical_partition(partition)

    {query, options, invalid?} =
      Enum.reduce(
        ["status", "correlation_id", "from", "to", "limit", "cursor"],
        {base, [], false},
        fn key, {query, options, invalid?} ->
          case normalize_list_param(key, params[key]) do
            :skip ->
              {query, options, invalid?}

            {:ok, url_value, option_value} ->
              {Map.put(query, key, url_value),
               Keyword.put(options, String.to_existing_atom(key), option_value), invalid?}

            :error ->
              {query, options, true}
          end
        end
      )

    known = @partition_params ++ ["status", "correlation_id", "from", "to", "limit", "cursor"]
    {query, Keyword.put_new(options, :limit, 50), invalid? or Map.keys(params) -- known != []}
  end

  defp normalize_list_param(_key, nil), do: :skip
  defp normalize_list_param(_key, ""), do: :skip

  defp normalize_list_param("status", value) when value in ~w(running complete failed),
    do: {:ok, value, value}

  defp normalize_list_param("correlation_id", value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= 512, do: {:ok, value, value}, else: :error
  end

  defp normalize_list_param(key, value) when key in ["from", "to"] and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime), datetime}
      _error -> :error
    end
  end

  defp normalize_list_param("limit", value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100 -> {:ok, Integer.to_string(limit), limit}
      _error -> :error
    end
  end

  defp normalize_list_param("cursor", value) when is_binary(value), do: {:ok, value, value}
  defp normalize_list_param(_key, _value), do: :error

  defp canonicalize(socket, params, query, invalid?) do
    current = Map.take(params, Map.keys(params) -- ["recall_run_id"])

    if invalid? or current != query do
      socket
      |> maybe_invalid_flash(invalid?)
      |> push_patch(to: index_path(query), replace: true)
    else
      socket
    end
  end

  defp maybe_invalid_flash(socket, true),
    do: put_flash(socket, :error, "One invalid recall parameter was removed.")

  defp maybe_invalid_flash(socket, false), do: socket

  defp canonical_partition(partition) do
    %{
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }
  end

  defp index_path(query), do: "/memory/recall?#{URI.encode_query(query)}"

  defp detail_path(id, query) do
    "/memory/recall/#{id}?#{URI.encode_query(query)}"
  end

  defp rank_movement(candidate) do
    case {candidate.pre_reranker_rank, candidate.post_reranker_rank} do
      {before, current} when not is_integer(before) or not is_integer(current) -> "unavailable"
      {before, current} when before == current -> "unchanged at #{before}"
      {before, current} when current < before -> "moved up from #{before} to #{current}"
      {before, current} -> "moved down from #{before} to #{current}"
    end
  end

  defp normalize_candidate_filters(params) do
    selection =
      if params["selection"] in ~w(all selected rejected), do: params["selection"], else: "all"

    kind = if params["kind"] in @candidate_kinds, do: params["kind"], else: nil

    cursor =
      case Integer.parse(params["candidate_cursor"] || "0") do
        {value, ""} when value >= 0 and value <= 500 -> value
        _invalid -> 0
      end

    filters =
      %{"selection" => selection}
      |> maybe_put("kind", kind)
      |> maybe_put("candidate_cursor", if(cursor > 0, do: Integer.to_string(cursor)))

    invalid? =
      (not is_nil(params["selection"]) and params["selection"] != selection) or
        (not is_nil(params["kind"]) and is_nil(kind)) or
        (not is_nil(params["candidate_cursor"]) and cursor == 0 and
           params["candidate_cursor"] != "0")

    {filters, invalid?}
  end

  defp candidate_page(candidates, filters) do
    offset = String.to_integer(filters["candidate_cursor"] || "0")
    filtered = Enum.filter(candidates, &candidate_matches?(&1, filters))
    page = Enum.slice(filtered, offset, @candidate_page_size)

    next =
      if length(filtered) > offset + @candidate_page_size,
        do: Integer.to_string(offset + @candidate_page_size)

    {page, next}
  end

  defp candidate_matches?(candidate, filters) do
    selection = filters["selection"]

    (selection == "all" or (selection == "selected" and candidate.selected) or
       (selection == "rejected" and not candidate.selected)) and
      (is_nil(filters["kind"]) or candidate.candidate_kind == filters["kind"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp source_refs(candidate), do: get_in(candidate.source_refs || %{}, ["refs"]) || []
  defp duration(nil), do: "—"
  defp duration(value), do: "#{value} ms"
  defp score(nil), do: "—"
  defp score(value), do: :erlang.float_to_binary(value / 1, decimals: 4)
  defp rank(nil), do: "—"
  defp rank(value), do: to_string(value)

  defp channel_summary(run) do
    run.channel_availability
    |> Enum.map(fn {channel, available} ->
      state =
        cond do
          available -> "available"
          Map.has_key?(run.channel_errors, channel) -> "failed"
          true -> "skipped"
        end

      "#{channel}=#{state}"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp rejection_explanation(nil), do: "Included by the selection policy."
  defp rejection_explanation("diversity"), do: "Excluded by diversity limits."

  defp rejection_explanation("token_budget"),
    do: "Excluded because the token budget was exhausted."

  defp rejection_explanation("lifecycle"), do: "Excluded by lifecycle policy."
  defp rejection_explanation("duplicate"), do: "Excluded as a duplicate candidate."
  defp rejection_explanation("below_threshold"), do: "Excluded below the relevance threshold."
  defp rejection_explanation("superseded"), do: "Excluded because it was superseded."
  defp rejection_explanation("disputed"), do: "Excluded because it is disputed."
  defp rejection_explanation("archived"), do: "Excluded because it is archived."
  defp rejection_explanation("channel_error"), do: "Excluded after a retrieval channel error."
  defp rejection_explanation("review"), do: "Excluded pending review."
  defp rejection_explanation(_unknown), do: "Excluded by recall policy."
end
