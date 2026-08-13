defmodule Backplane.Admin.MemoryActionsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Operations

  @page_size 25

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/actions",
         partition: nil,
         rows: [],
         selected: nil,
         offset: 0,
         project: nil,
         next_offset: nil,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case exact_partition(params) do
      {:ok, partition} -> load(socket, partition, params)
      _ -> {:noreply, assign(socket, partition: nil, rows: [], selected: nil, error: nil)}
    end
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/memory/actions?#{selection_query(raw, ["project"])}")}

  @impl true
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="actions-partition" title="Actions" subtitle="Partition-owned coordination work" path="/memory/actions" extra={[{"project", "Project"}]} />
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-actions">
      <.memory_page_header title="Actions" subtitle="Partition-owned coordination work" />
      <.dm_alert :if={@error} id="actions-error" variant="error" title="Actions unavailable">The bounded exact-partition query failed.</.dm_alert>
      <.dm_card :if={@selected} id="action-detail" variant="bordered" padding="lg" class="mb-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="text-lg font-semibold">{@selected.action.title}</h2>
            <p class="text-sm opacity-70">{@selected.action.description || "No description"}</p>
          </div>
          <.dm_badge variant={status_variant(@selected.action.status)} size="sm">{@selected.action.status}</.dm_badge>
        </div>
        <dl id="action-provenance" class="mt-4 grid gap-3 text-sm md:grid-cols-2">
          <.origin_rows label="Observation" ids={@selected.action.source_observation_ids} />
          <.origin_rows label="Memory" ids={@selected.action.source_memory_ids} />
          <.origin_rows label="Session" ids={@selected.action.source_session_ids} />
          <.origin_rows label="Lesson" ids={@selected.action.source_lesson_ids} />
          <.origin_rows label="Crystal" ids={@selected.action.source_crystal_ids} />
        </dl>
        <div id="action-lease" class="mt-4 text-sm">
          <%= if @selected.lease do %>
            <span class="font-medium">Leased by {@selected.lease.holder_agent_id}</span>
            <span class="opacity-70"> until {format_datetime(@selected.lease.expires_at)}</span>
          <% else %>
            <span class="opacity-70">Unleased</span>
          <% end %>
        </div>
      </.dm_card>
      <.dm_card :if={@rows == [] and !@error} id="actions-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No actions in this partition</h2></.dm_card>
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-actions-table" data={@rows} compact hover zebra>
          <:col :let={action} label="Action"><.link patch={detail_path(@partition, @project, @offset, action.id)} class="text-primary underline">{action.title}</.link></:col>
          <:col :let={action} label="Status"><.dm_badge variant={status_variant(action.status)} size="sm">{action.status}</.dm_badge></:col>
          <:col :let={action} label="Priority">{action.priority}</:col>
          <:col :let={action} label="Project">{action.project || "—"}</:col>
          <:col :let={action} label="Updated">{format_datetime(action.updated_at)}</:col>
        </.dm_table>
      </div>
      <nav aria-label="Action pagination" class="mt-4 flex justify-end gap-2">
        <.link :if={@offset > 0} id="actions-previous" patch={page_path(@partition, @project, max(0, @offset - @page_size))} class="text-primary underline">Previous</.link>
        <.link :if={@next_offset} id="actions-next" patch={page_path(@partition, @project, @next_offset)} class="text-primary underline">Next</.link>
      </nav>
      <div class="mt-5 flex flex-wrap gap-3 text-sm"><.link navigate={~p"/memory/sessions?#{partition_query(@partition)}"} class="text-primary underline">Sessions</.link><.link navigate={~p"/memory/graph?#{partition_query(@partition)}"} class="text-primary underline">Graph</.link><.link navigate={~p"/memory/audit?#{partition_query(@partition)}"} class="text-primary underline">Audit</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])
    project = blank_nil(params["project"])
    opts = [limit: @page_size, offset: offset] ++ if(project, do: [project: project], else: [])

    case Operations.list_actions(partition, opts) do
      {:ok, result} ->
        selected = load_detail(params["action"], partition)

        {:noreply,
         assign(socket,
           partition: partition,
           rows: result.entries,
           selected: selected,
           offset: offset,
           project: project,
           next_offset: result.next_offset,
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, partition: partition, rows: [], selected: nil, error: reason)}
    end
  end

  defp load_detail(nil, _partition), do: nil

  defp load_detail(action_id, partition) do
    case Operations.get_action_detail(action_id, partition) do
      {:ok, detail} -> detail
      _ -> nil
    end
  end

  defp page_path(partition, project, offset) do
    query = Map.put(partition_query(partition), "offset", offset)
    query = if project, do: Map.put(query, "project", project), else: query
    ~p"/memory/actions?#{query}"
  end

  defp detail_path(partition, project, offset, action_id) do
    query =
      partition_query(partition)
      |> Map.put("offset", offset)
      |> Map.put("action", action_id)

    query = if project, do: Map.put(query, "project", project), else: query
    ~p"/memory/actions?#{query}"
  end

  attr(:label, :string, required: true)
  attr(:ids, :list, required: true)

  defp origin_rows(assigns) do
    ~H"""
    <div :for={id <- @ids}>
      <dt class="font-medium">{@label}</dt>
      <dd class="break-all font-mono text-xs opacity-80">{id}</dd>
    </div>
    """
  end

  defp blank_nil(nil), do: nil
  defp blank_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
