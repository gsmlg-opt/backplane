defmodule Backplane.Admin.MemoryTimelineLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Projections.ReadModels

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
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case exact_partition(params) do
      {:ok, partition} -> load(socket, partition, params)
      _ -> {:noreply, assign(socket, partition: nil, rows: [], offset: 0, error: nil)}
    end
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
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="timeline-partition" title="Timeline" subtitle="Projected observations in deterministic source order" path="/memory/timeline" extra={[{"session", "Session (optional)"}]} />
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-timeline">
      <.memory_page_header title="Timeline" subtitle="Projected observations in deterministic source order" />
      <.form for={%{}} id="timeline-filters" phx-submit="filter" class="mb-4 grid gap-3 rounded-xl border border-outline-variant p-4 md:grid-cols-4">
        <label class="text-sm">Event type<input name="filters[event_type]" value={@filters["event_type"]} class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <label class="text-sm">Tool<input name="filters[tool]" value={@filters["tool"]} class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <label class="text-sm">Minimum importance<input type="number" name="filters[minimum_importance]" value={@filters["minimum_importance"]} class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <label class="text-sm">Error status<select name="filters[error]" class="mt-1 w-full rounded border border-outline-variant bg-surface p-2"><option value="" selected={@filters["error"] == ""}>Any</option><option value="false" selected={@filters["error"] == "false"}>Success</option><option value="true" selected={@filters["error"] == "true"}>Error</option></select></label>
        <label class="text-sm">File<input name="filters[file]" value={@filters["file"]} class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <label class="text-sm">From<input name="filters[from]" value={@filters["from"]} placeholder="ISO 8601" class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <label class="text-sm">To<input name="filters[to]" value={@filters["to"]} placeholder="ISO 8601" class="mt-1 w-full rounded border border-outline-variant bg-surface p-2" /></label>
        <div class="flex items-end"><button type="submit" class="rounded bg-primary px-4 py-2 text-on-primary">Apply filters</button></div>
      </.form>
      <.dm_alert :if={@error} id="timeline-error" variant="error" title="Timeline unavailable">The bounded projection query failed.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="timeline-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No projected observations</h2><p class="mt-1 text-sm text-on-surface-variant">The session may be pending, skipped, or have no accepted observations.</p></.dm_card>
      <ol :if={@rows != []} id="memory-timeline-list" class="space-y-3">
        <li :for={row <- @rows} class="rounded-xl border border-outline-variant bg-surface-container p-4 text-on-surface">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <strong>{row.event_type}</strong>
            <.dm_badge variant={status_variant(row.processing_status)} size="sm">{row.processing_status}</.dm_badge>
          </div>
          <p class="mt-2 whitespace-pre-wrap">{row.content || row.message || "No display content"}</p>
          <p class="mt-2 text-xs text-on-surface-variant">Session {row.session_id} · {format_datetime(row.occurred_at)}</p>
        </li>
      </ol>
      <nav aria-label="Timeline pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="timeline-previous" patch={page_path(@partition, @session, @filters, max(0, @offset - @page_size))}>Previous</.memory_link_button>
        <.memory_link_button :if={length(@rows) == @page_size} id="timeline-next" patch={page_path(@partition, @session, @filters, @offset + @page_size)}>Next</.memory_link_button>
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

    case ReadModels.timeline(opts) do
      {:ok, subjects} ->
        rows =
          Enum.flat_map(subjects, fn subject ->
            Enum.map(
              subject.observations,
              &Map.merge(&1, %{processing_status: subject.processing_status})
            )
          end)

        {:noreply,
         assign(socket,
           partition: partition,
           rows: rows,
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
end
