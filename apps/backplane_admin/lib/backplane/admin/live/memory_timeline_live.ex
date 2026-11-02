defmodule Backplane.Admin.MemoryTimelineLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Operations.Inventory

  @page_size 50

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/timeline",
         page_size: @page_size,
         partition: nil,
         rows: [],
         session: nil,
         filters: empty_filters(),
         offset: 0,
         next_offset: nil,
         total: 0,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    load(socket, browse_scope(params), params)
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/memory/timeline?#{selection_query(raw, ["session"])}")}

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      socket.assigns.partition
      |> partition_query()
      |> maybe_query("session", socket.assigns.session)
      |> Map.merge(normalize_filter_query(filters))

    {:noreply, push_patch(socket, to: ~p"/memory/timeline?#{query}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-timeline">
      <.memory_page_header title="Timeline" subtitle="Recorded observations, tools, and outcomes in source order" />
      <details id="timeline-filter-panel" class="memory-disclosure" open={@filters != empty_filters()}>
        <summary>Filter observations</summary>
        <.form for={%{}} id="timeline-filters" phx-submit="filter" class="memory-disclosure-body grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.dm_input id="timeline-event-type" name="filters[event_type]" label="Event type" value={@filters["event_type"]} />
          <.dm_input id="timeline-tool" name="filters[tool]" label="Tool" value={@filters["tool"]} />
          <.dm_input id="timeline-importance" name="filters[minimum_importance]" label="Minimum importance" type="number" value={@filters["minimum_importance"]} />
          <.dm_select id="timeline-error-status" name="filters[error]" label="Error status" value={@filters["error"]} options={[{"", "Any"}, {"false", "Success"}, {"true", "Error"}]} />
          <.dm_input id="timeline-file" name="filters[file]" label="File" value={@filters["file"]} />
          <.dm_input id="timeline-from" name="filters[from]" label="From (UTC)" value={@filters["from"]} placeholder="2026-10-24T09:00:00Z" />
          <.dm_input id="timeline-to" name="filters[to]" label="To (UTC)" value={@filters["to"]} placeholder="2026-10-24T18:00:00Z" />
          <div class="flex items-end"><.dm_btn type="submit" native_submit variant="primary">Apply filters</.dm_btn></div>
        </.form>
      </details>
      <.dm_alert :if={@error} id="timeline-error" variant="error" title="Timeline unavailable">The bounded projection query failed.</.dm_alert>
      <p :if={!@error} id="timeline-count" class="mb-3 text-sm">{@total} matching observations</p>
      <.dm_card :if={@rows == [] and !@error} id="timeline-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No projected observations</h2><p class="mt-1 text-sm text-on-surface-variant">The session may be pending, skipped, or have no accepted observations.</p></.dm_card>
      <.dm_timeline :if={@rows != []} id="memory-timeline-list" class="mt-4">
        <:item
          :for={row <- @rows}
          title={timeline_title(row)}
          time={format_datetime(row.occurred_at)}
          color={timeline_color(row)}
          icon={timeline_icon(row)}
          completed={row.processing_status in ["complete", "done"]}
        >
          <div class="mb-1.5 flex flex-wrap items-center gap-2">
            <.dm_badge variant={status_variant(row.processing_status)} size="sm">
              {row.processing_status}
            </.dm_badge>
            <span :if={row.is_error} class="text-xs font-medium text-error">Error</span>
            <span :if={row.importance} class="text-xs text-on-surface-variant">
              Importance: {row.importance}
            </span>
            <span :if={row.commit_hash} class="font-mono text-xs text-on-surface-variant">
              {String.slice(row.commit_hash, 0, 8)}
            </span>
          </div>
          <p class="whitespace-pre-wrap text-sm text-on-surface">
            {row.content || row.message || "No display content"}
          </p>
          <div :if={row.file_paths && row.file_paths != []} class="mt-2 flex flex-wrap gap-1">
            <span
              :for={file <- row.file_paths}
              class="inline-block rounded bg-surface-container-high px-1.5 py-0.5 font-mono text-xs text-on-surface-variant"
            >
              {file}
            </span>
          </div>
          <p class="mt-2 text-xs text-on-surface-variant">
            Session {row.session_id}
            <span :if={row.agent_id}> · Agent {row.agent_id}</span>
          </p>
        </:item>
      </.dm_timeline>
      <nav :if={!@error} aria-label="Timeline pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="timeline-previous" patch={page_path(@partition, @session, @filters, max(0, @offset - @page_size))}>Previous</.memory_link_button>
        <.memory_link_button :if={@next_offset != nil} id="timeline-next" patch={page_path(@partition, @session, @filters, @offset + @page_size)}>Next</.memory_link_button>
      </nav>
    </div>
    """
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])
    session = blank_nil(params["session"])
    filters = Map.merge(empty_filters(), Map.take(params, Map.keys(empty_filters())))

    opts =
      [limit: @page_size, offset: offset]
      |> Keyword.merge(Map.to_list(partition))
      |> put_filter(:event_type, filters["event_type"])
      |> put_filter(:tool_name, filters["tool"])
      |> put_integer_filter(:minimum_importance, filters["minimum_importance"])
      |> put_boolean_filter(:is_error, filters["error"])
      |> put_filter(:file_path, filters["file"])
      |> put_filter(:occurred_from, filters["from"])
      |> put_filter(:occurred_to, filters["to"])

    opts = if session, do: Keyword.put(opts, :session_id, session), else: opts

    case Inventory.timeline(partition, opts) do
      {:ok, %{entries: rows} = result} ->
        {:noreply,
         assign(socket,
           partition: partition,
           rows: rows,
           next_offset: result.next_offset,
           total: result.total,
           offset: offset,
           session: session,
           filters: filters,
           error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           partition: partition,
           rows: [],
           total: 0,
           next_offset: nil,
           offset: offset,
           session: session,
           filters: filters,
           error: reason
         )}
    end
  end

  defp page_path(partition, session, filters, offset) do
    query =
      partition
      |> partition_query()
      |> maybe_query("session", session)
      |> Map.merge(normalize_filter_query(filters))
      |> Map.put("offset", offset)

    ~p"/memory/timeline?#{query}"
  end

  defp empty_filters,
    do: Map.new(~w(event_type tool minimum_importance error file from to), &{&1, ""})

  defp normalize_filter_query(filters) do
    filters
    |> Map.take(Map.keys(empty_filters()))
    |> Map.new(fn {key, value} -> {key, String.trim(to_string(value))} end)
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
  end

  defp maybe_query(query, _key, nil), do: query
  defp maybe_query(query, key, value), do: Map.put(query, key, value)

  defp put_filter(opts, _key, value) when value in [nil, ""], do: opts
  defp put_filter(opts, key, value), do: Keyword.put(opts, key, String.trim(value))

  defp put_integer_filter(opts, _key, value) when value in [nil, ""], do: opts

  defp put_integer_filter(opts, key, value) do
    case Integer.parse(value) do
      {integer, ""} -> Keyword.put(opts, key, integer)
      _invalid -> Keyword.put(opts, key, :invalid)
    end
  end

  defp put_boolean_filter(opts, _key, value) when value in [nil, ""], do: opts
  defp put_boolean_filter(opts, key, "true"), do: Keyword.put(opts, key, true)
  defp put_boolean_filter(opts, key, "false"), do: Keyword.put(opts, key, false)
  defp put_boolean_filter(opts, key, _value), do: Keyword.put(opts, key, :invalid)

  defp blank_nil(nil), do: nil
  defp blank_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp timeline_title(row) do
    cond do
      row.event_type && row.tool_name && row.tool_name != "" ->
        "#{row.event_type} · #{row.tool_name}"

      row.event_type ->
        row.event_type

      row.tool_name ->
        row.tool_name

      true ->
        "Observation"
    end
  end

  defp timeline_color(row) do
    cond do
      row.is_error || row.processing_status in ["failed", "dead_letter"] -> "error"
      row.processing_status in ["complete", "done"] -> "success"
      row.processing_status in ["pending", "running", "in_progress"] -> "warning"
      true -> "primary"
    end
  end

  defp timeline_icon(row) do
    cond do
      row.is_error || row.processing_status in ["failed", "dead_letter"] ->
        "alert-circle"

      is_binary(row.event_type) && String.starts_with?(row.event_type, "agent.tool") ->
        "wrench"

      is_binary(row.event_type) && String.starts_with?(row.event_type, "agent.prompt") ->
        "message-text"

      is_binary(row.event_type) && String.starts_with?(row.event_type, "agent.session") ->
        "account-clock"

      is_binary(row.event_type) && String.starts_with?(row.event_type, "agent.file") ->
        "file-document"

      is_binary(row.event_type) && String.starts_with?(row.event_type, "agent.commit") ->
        "source-commit"

      row.tool_name && row.tool_name != "" ->
        "wrench"

      row.processing_status in ["complete", "done"] ->
        "check-circle"

      true ->
        nil
    end
  end
end
