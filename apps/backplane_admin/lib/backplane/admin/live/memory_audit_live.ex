defmodule Backplane.Admin.MemoryAuditLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Audit

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
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case exact_partition(params) do
      {:ok, partition} ->
        offset = page(params["offset"])

        opts =
          [limit: @page_size, offset: offset]
          |> maybe(:operation, params["operation"])
          |> maybe(:actor, params["actor"])

        rows = Audit.list(partition, opts)
        target = blank_nil(params["target"])
        rows = if target, do: Enum.filter(rows, &target?(&1.target_ids, target)), else: rows

        {:noreply,
         assign(socket,
           partition: partition,
           rows: rows,
           offset: offset,
           error: nil,
           operation: blank_nil(params["operation"]),
           actor: blank_nil(params["actor"]),
           target: target
         )}

      _ ->
        {:noreply, assign(socket, partition: nil, rows: [], error: nil)}
    end
  rescue
    error -> {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: ~p"/memory/audit?#{selection_query(raw, ["operation", "actor", "target"])}"
       )}

  @impl true
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="audit-partition" title="Audit" subtitle="Append-only memory governance history" path="/memory/audit" extra={[{"operation", "Operation (optional)"}, {"actor", "Actor (optional)"}, {"target", "Target ID (optional)"}]} />
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-audit">
      <.memory_page_header title="Audit" subtitle="Append-only memory governance history" />
      <.dm_alert :if={@error} id="audit-error" variant="error" title="Audit unavailable">Audit entries could not be loaded.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="audit-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No audit entries match</h2></.dm_card>
      <div class="overflow-x-auto"><.dm_table :if={@rows != []} id="memory-audit-table" data={@rows} compact hover zebra><:col :let={row} label="Operation">{row.operation}</:col><:col :let={row} label="Actor">{row.actor}</:col><:col :let={row} label="Targets"><code>{Jason.encode!(row.target_ids)}</code></:col><:col :let={row} label="Created">{format_datetime(row.created_at)}</:col></.dm_table></div>
      <nav aria-label="Audit pagination" class="mt-4 flex justify-end gap-2"><.memory_link_button :if={@offset > 0} id="audit-previous" patch={page_path(assigns, max(0, @offset - @page_size))}>Previous</.memory_link_button><.memory_link_button :if={length(@rows) == @page_size} id="audit-next" patch={page_path(assigns, @offset + @page_size)}>Next</.memory_link_button></nav>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/actions?#{partition_query(@partition)}"} class="text-primary underline">Actions</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end

  defp maybe(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, String.trim(value))
  defp blank_nil(nil), do: nil
  defp blank_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp target?(values, target) when is_list(values), do: target in Enum.map(values, &to_string/1)

  defp target?(values, target) when is_map(values),
    do: target in Enum.map(Map.values(values), &to_string/1)

  defp target?(_, _), do: false

  defp page_path(assigns, offset) do
    query =
      partition_query(assigns.partition)
      |> optional("operation", assigns.operation)
      |> optional("actor", assigns.actor)
      |> optional("target", assigns.target)
      |> Map.put("offset", offset)

    ~p"/memory/audit?#{query}"
  end

  defp optional(query, _key, nil), do: query
  defp optional(query, key, value), do: Map.put(query, key, value)
end
