defmodule Backplane.Admin.MemorySessionsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Projections.{ReadModels, SessionDetail}

  @page_size 25

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/sessions",
         page_size: @page_size,
         partition: nil,
         rows: [],
         detail: nil,
         offset: 0,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case exact_partition(params) do
      {:ok, partition} ->
        load(socket, partition, params)

      {:error, :partition_required} ->
        {:noreply, assign(socket, partition: nil, rows: [], detail: nil, offset: 0, error: nil)}
    end
  end

  defp load(%{assigns: %{live_action: :show}} = socket, partition, %{"session_id" => session_id}) do
    case SessionDetail.get(partition, session_id) do
      {:ok, detail} ->
        {:noreply, assign(socket, partition: partition, detail: detail, rows: [], error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, partition: partition, detail: nil, rows: [], error: reason)}
    end
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])

    opts =
      [limit: @page_size, offset: offset]
      |> put_filter(:project, params["project"])
      |> put_filter(:session_id, params["session"])
      |> Keyword.merge(Map.to_list(partition))

    case ReadModels.sessions(opts) do
      {:ok, rows} ->
        {:noreply,
         assign(socket, partition: partition, rows: rows, detail: nil, offset: offset, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, partition: partition, detail: nil, error: reason)}
    end
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/sessions?#{selection_query(raw)}")}

  @impl true
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="sessions-partition" title="Sessions" subtitle="Canonical projected sessions and processing state" path="/memory/sessions" />
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div id="memory-session-detail">
      <.memory_page_header title="Session detail" subtitle={@detail && @detail.session_id || "Canonical session detail unavailable"} />
      <.dm_alert :if={@error} id="session-detail-error" variant="error" title="Session unavailable">The exact-partition session detail could not be loaded.</.dm_alert>
      <div :if={@detail} class="space-y-4">
        <.dm_card variant="bordered" padding="lg">
          <h2 class="text-lg font-semibold">{@detail.session_id}</h2>
          <dl class="mt-3 grid gap-3 md:grid-cols-3">
            <div><dt class="text-xs text-on-surface-variant">Project</dt><dd>{@detail.project || "—"}</dd></div>
            <div><dt class="text-xs text-on-surface-variant">Host / agent</dt><dd>{@detail.host_id} / {@detail.agent_id || "—"}</dd></div>
            <div><dt class="text-xs text-on-surface-variant">Integration / model</dt><dd>{@detail.integration || "—"} / {@detail.model || "—"}</dd></div>
            <div><dt class="text-xs text-on-surface-variant">Started</dt><dd>{format_datetime(@detail.started_at)}</dd></div>
            <div><dt class="text-xs text-on-surface-variant">Ended</dt><dd>{format_datetime(@detail.ended_at)}</dd></div>
            <div><dt class="text-xs text-on-surface-variant">Duration</dt><dd>{format_duration(@detail.duration_ms)}</dd></div>
          </dl>
        </.dm_card>
        <.dm_card id="session-first-prompt" variant="bordered" padding="lg"><h2 class="font-semibold">First prompt</h2><p class="mt-2 whitespace-pre-wrap">{@detail.first_prompt || "—"}</p></.dm_card>
        <.dm_card variant="bordered" padding="lg"><h2 class="font-semibold">Summary</h2><p class="mt-2 whitespace-pre-wrap">{@detail.summary && @detail.summary.content || "Pending"}</p></.dm_card>
        <div class="grid gap-4 md:grid-cols-2">
          <.dm_card id="session-tool-breakdown" variant="bordered" padding="lg"><h2 class="font-semibold">Tools</h2><p :for={{tool, count} <- @detail.tool_breakdown}>{tool}: {count}</p></.dm_card>
          <.dm_card id="session-event-breakdown" variant="bordered" padding="lg"><h2 class="font-semibold">Events ({@detail.observation_count})</h2><p :for={{type, count} <- @detail.event_type_breakdown}>{type}: {count}</p></.dm_card>
          <.dm_card id="session-files" variant="bordered" padding="lg"><h2 class="font-semibold">Files</h2><p :for={file <- @detail.files}>{file}</p></.dm_card>
          <.dm_card id="session-commits" variant="bordered" padding="lg"><h2 class="font-semibold">Commits</h2><p :for={commit <- @detail.commits}>{commit}</p></.dm_card>
        </div>
        <.dm_card id="session-processing" variant="bordered" padding="lg"><h2 class="font-semibold">Processing</h2><div class="mt-2 flex flex-wrap gap-2"><.dm_badge :for={{name, state} <- @detail.processing} variant={status_variant(state.status)} size="sm">{name}: {state.status}</.dm_badge></div><p :for={{name, %{last_error: error}} <- @detail.processing} :if={error} class="text-error">{name}: {error}</p></.dm_card>
        <.dm_card id="session-relations" variant="bordered" padding="lg"><h2 class="font-semibold">Relations</h2><p>Source: {@detail.source_session_id || "—"}</p><p>Children: {Enum.join(@detail.child_session_ids, ", ")}</p><p>Memories: {length(@detail.links.memories)} · Lessons: {length(@detail.links.lessons)} · Actions: {length(@detail.links.actions)} · Crystals: {length(@detail.links.crystals)}</p></.dm_card>
        <div class="flex flex-wrap gap-3">
          <.link navigate={~p"/memory/timeline?#{Map.put(partition_query(@partition), "session", @detail.session_id)}"} class="text-primary underline">Timeline</.link>
          <.link navigate={~p"/memory/replay?#{Map.put(partition_query(@partition), "session", @detail.session_id)}"} class="text-primary underline">Replay</.link>
          <.link navigate={~p"/memory/memories?#{Map.put(partition_query(@partition), "session", @detail.session_id)}"} class="text-primary underline">Memories</.link>
          <.link navigate={~p"/memory/actions?#{Map.put(partition_query(@partition), "project", @detail.project || "")}"} class="text-primary underline">Actions</.link>
          <.link navigate={~p"/memory/lessons?#{partition_query(@partition)}"} class="text-primary underline">Lessons</.link>
          <.link navigate={~p"/memory/crystals?#{partition_query(@partition)}"} class="text-primary underline">Crystals</.link>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-sessions">
      <.memory_page_header title="Sessions" subtitle="Canonical projected sessions and processing state" />
      <.dm_alert :if={@error} id="sessions-error" variant="error" title="Sessions unavailable">The bounded session query failed.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="sessions-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No sessions in this partition</h2></.dm_card>
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-sessions-table" data={@rows} compact hover zebra>
          <:col :let={row} label="Session"><.link navigate={~p"/memory/sessions/#{row.session_id}?#{partition_query(@partition)}"} class="text-primary underline">{row.session_id}</.link></:col>
          <:col :let={row} label="Project">{row.project || "—"}</:col>
          <:col :let={row} label="Lifecycle"><.dm_badge variant={status_variant(row.status)} size="sm">{row.status}</.dm_badge></:col>
          <:col :let={row} label="Processing"><.dm_badge variant={status_variant(row.processing_status)} size="sm">{row.processing_status}</.dm_badge></:col>
          <:col :let={row} label="Started">{format_datetime(row.started_at)}</:col>
          <:col :let={row} label="Links">
            <div class="flex gap-2">
              <.link navigate={~p"/memory/timeline?#{Map.merge(partition_query(@partition), %{"session" => row.session_id})}"} class="text-primary underline">Timeline</.link>
              <.link navigate={~p"/memory/replay?#{Map.merge(partition_query(@partition), %{"session" => row.session_id})}"} class="text-primary underline">Replay</.link>
              <.link navigate={~p"/memory/sessions?#{Map.merge(partition_query(@partition), %{"session" => row.session_id})}"} class="text-primary underline">Session summary</.link>
              <.link navigate={~p"/memory/actions?#{Map.merge(partition_query(@partition), %{"project" => row.project || ""})}"} class="text-primary underline">Actions</.link>
              <.link navigate={~p"/memory/lessons?#{partition_query(@partition)}"} class="text-primary underline">Lessons</.link>
              <.link navigate={~p"/memory/crystals?#{partition_query(@partition)}"} class="text-primary underline">Crystals</.link>
            </div>
          </:col>
        </.dm_table>
      </div>
      <nav aria-label="Session pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="sessions-previous" patch={~p"/memory/sessions?#{Map.put(partition_query(@partition), "offset", max(0, @offset - @page_size))}"}>Previous</.memory_link_button>
        <.memory_link_button :if={length(@rows) == @page_size} id="sessions-next" patch={~p"/memory/sessions?#{Map.put(partition_query(@partition), "offset", @offset + @page_size)}"}>Next</.memory_link_button>
      </nav>
    </div>
    """
  end

  defp put_filter(opts, _key, value) when value in [nil, ""], do: opts
  defp put_filter(opts, key, value), do: Keyword.put(opts, key, String.trim(value))

  defp format_duration(nil), do: "—"
  defp format_duration(milliseconds), do: "#{milliseconds} ms"
end
