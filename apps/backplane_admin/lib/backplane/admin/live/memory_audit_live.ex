defmodule Backplane.Admin.MemoryAuditLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents,
    only: [memory_link_button: 1, memory_page_header: 1, memory_blank_state: 1]

  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Operations.Inventory

  @page_size 50

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/audit",
         page_size: @page_size,
         partition: nil,
         rows: [],
         offset: 0,
         next_offset: nil,
         total: 0,
         empty_purge_count: 0,
         include_empty_runs: false,
         error: nil,
         operation: nil,
         actor: nil,
         target: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    partition = browse_scope(params)
    offset = page(params["offset"])
    include_empty_runs = params["include_empty_runs"] == "true"

    opts =
      [limit: @page_size, offset: offset, include_empty_runs: include_empty_runs]
      |> maybe(:operation, params["operation"])
      |> maybe(:actor, params["actor"])
      |> maybe(:target, params["target"])

    {:ok, result} = Inventory.audit(partition, opts)

    {:noreply,
     assign(socket,
       partition: partition,
       rows: result.entries,
       offset: offset,
       next_offset: result.next_offset,
       total: result.total,
       empty_purge_count: result.empty_purge_count,
       include_empty_runs: include_empty_runs,
       error: nil,
       operation: blank_nil(params["operation"]),
       actor: blank_nil(params["actor"]),
       target: blank_nil(params["target"])
     )}
  rescue
    error ->
      {:noreply,
       assign(socket,
         partition: browse_scope(params),
         rows: [],
         total: 0,
         empty_purge_count: 0,
         include_empty_runs: params["include_empty_runs"] == "true",
         offset: page(params["offset"]),
         next_offset: nil,
         error: error,
         operation: blank_nil(params["operation"]),
         actor: blank_nil(params["actor"]),
         target: blank_nil(params["target"])
       )}
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           ~p"/memory/audit?#{selection_query(raw, ["operation", "actor", "target", "include_empty_runs"])}"
       )}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-audit">
      <.memory_page_header title="Audit" subtitle="Append-only memory governance history" />
      <.dm_alert :if={@error} id="audit-error" variant="error" title="Audit unavailable">Audit entries could not be loaded.</.dm_alert>
      <div :if={!@error} class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <p id="audit-count" class="text-sm">{@total} matching audit entries</p>
        <div :if={@empty_purge_count > 0} class="flex flex-wrap items-center gap-3 text-sm">
          <p id="audit-empty-runs-summary" class="text-on-surface-variant">
            {@empty_purge_count} empty cleanup runs {if @include_empty_runs, do: "included", else: "hidden"}
          </p>
          <.memory_link_button id="audit-toggle-empty-runs" variant="ghost" patch={page_path(%{assigns | include_empty_runs: !@include_empty_runs}, 0)}>
            {if @include_empty_runs, do: "Hide empty cleanup runs", else: "Show empty cleanup runs"}
          </.memory_link_button>
        </div>
      </div>
      <.memory_blank_state :if={@rows == [] and !@error} id="audit-empty" title="No audit entries match" description="Memory governance actions create a permanent record here." icon="text-box-search-outline" />
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-audit-table" data={@rows} compact hover zebra>
          <:col :let={row} label="Operation">{row.operation}</:col>
          <:col :let={row} label="Actor">{row.actor}</:col>
          <:col :let={row} label="Targets">
            <%= if row.operation == "memory.activity.purge" and is_binary(row.metadata["cutoff"]) do %>
              <span>Before {row.metadata["cutoff"]}</span>
              <p class="mt-1 text-xs text-on-surface-variant">{purge_summary(row.metadata)}</p>
            <% else %>
              <code>{Jason.encode!(row.target_ids)}</code>
            <% end %>
          </:col>
          <:col :let={row} label="Created">{format_datetime(row.created_at)}</:col>
        </.dm_table>
      </div>
      <nav :if={!@error} aria-label="Audit pagination" class="mt-4 flex justify-end gap-2"><.memory_link_button :if={@offset > 0} id="audit-previous" patch={page_path(assigns, max(0, @offset - @page_size))}>Previous</.memory_link_button><.memory_link_button :if={@next_offset != nil} id="audit-next" patch={page_path(assigns, @offset + @page_size)}>Next</.memory_link_button></nav>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/actions?#{partition_query(@partition)}"} class="text-primary underline">Actions</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end

  defp maybe(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, String.trim(value))
  defp blank_nil(nil), do: nil
  defp blank_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp page_path(assigns, offset) do
    query =
      partition_query(assigns.partition)
      |> optional("operation", assigns.operation)
      |> optional("actor", assigns.actor)
      |> optional("target", assigns.target)
      |> optional("include_empty_runs", if(assigns.include_empty_runs, do: "true"))
      |> Map.put("offset", offset)

    ~p"/memory/audit?#{query}"
  end

  defp optional(query, _key, nil), do: query
  defp optional(query, key, value), do: Map.put(query, key, value)

  defp purge_summary(%{"daily_deleted" => daily, "contributions_deleted" => contributions})
       when is_integer(daily) and daily >= 0 and is_integer(contributions) and contributions >= 0 do
    if daily == 0 and contributions == 0,
      do: "No data removed",
      else: "#{daily} daily rows and #{contributions} contributions removed"
  end

  defp purge_summary(_metadata), do: "Deletion counts unavailable"
end
