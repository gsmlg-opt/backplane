defmodule Backplane.Admin.MemoryGraphLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Config

  alias Backplane.Memory.Operations.Inventory

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/graph",
         partition: nil,
         stats: nil,
         domain: "knowledge",
         relations: [],
         offset: 0,
         next_offset: nil,
         total: 0,
         graph_state: :disabled,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    load(socket, browse_scope(params), domain(params["domain"]), page(params["offset"]))
  rescue
    error -> {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/graph?#{selection_query(raw)}")}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-graph">
      <.memory_page_header title="Graph" subtitle="Stored knowledge graph inventory" />
      <.dm_alert :if={@error} id="graph-error" variant="error" title="Graph unavailable">Graph aggregates could not be loaded.</.dm_alert>
      <.dm_alert :if={@graph_state == :disabled} id="graph-disabled" variant="warning" title="Graph disabled">Enable the Memory pipeline and relation classifier to build graph data.</.dm_alert>
      <.dm_alert :if={@graph_state == :provider_unavailable} id="graph-provider-unavailable" variant="warning" title="Graph provider unavailable">Configure the Memory LLM provider before graph extraction can run.</.dm_alert>
      <.dm_card :if={@graph_state == :empty} id="graph-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No graph data matches</h2></.dm_card>
      <nav id="graph-domain-filters" class="mb-4 flex gap-2" aria-label="Graph relation domains">
        <.link :for={domain <- ~w(knowledge lifecycle provenance)} id={"graph-domain-#{domain}"} patch={~p"/memory/graph?#{domain_query(@partition, domain)}"} class="rounded border px-3 py-1 text-sm">{String.capitalize(domain)} ({Map.get(@stats && @stats.relation_count_by_domain || %{}, domain, 0)})</.link>
      </nav>
      <.dm_card id="graph-domain-relations" variant="bordered" padding="sm">
        <h2 class="font-semibold">{String.capitalize(@domain)} relations</h2>
        <p :if={@relations == []} class="mt-2 text-sm text-on-surface-variant">No relations in this domain.</p>
        <ul :if={@relations != []} class="mt-3 space-y-3">
          <li :for={relation <- @relations} id={"graph-relation-#{relation.id}"} class="rounded border p-3">
            <span class="font-medium">{relation.relation_type}</span>
            <span class="ml-2 text-xs text-on-surface-variant">{relation.status}</span>
            <p class="mt-1 text-sm">{relation.source_content} → {relation.target_content}</p>
          </li>
        </ul>
      </.dm_card>
      <p id="graph-count" class="mt-3 text-sm">{@total} matching relations in this domain</p>
      <nav aria-label="Graph pagination" class="mt-3 flex gap-3">
        <.link :if={@offset > 0} patch={~p"/memory/graph?#{Map.put(domain_query(@partition, @domain), "offset", max(0, @offset - 50))}"}>Previous</.link>
        <.link :if={@next_offset} patch={~p"/memory/graph?#{Map.put(domain_query(@partition, @domain), "offset", @next_offset)}"}>Next</.link>
      </nav>
      <div :if={@stats} id="graph-node-counts" class="grid gap-4 lg:grid-cols-2">
        <.dm_card variant="bordered" padding="sm"><h2 class="font-semibold">Nodes by type</h2><ul class="mt-3 space-y-2"><li :for={{type, count} <- sorted(@stats.node_count_by_type)} class="flex justify-between"><span>{type}</span><strong>{count}</strong></li></ul></.dm_card>
        <.dm_card variant="bordered" padding="sm"><h2 class="font-semibold">Edges by relation</h2><ul class="mt-3 space-y-2"><li :for={{relation, count} <- sorted(@stats.edge_count_by_relation)} class="flex justify-between"><span>{relation}</span><strong>{count}</strong></li></ul></.dm_card>
      </div>
      <div class="mt-5 flex flex-wrap gap-3 text-sm"><.link navigate={~p"/memory/memories?#{partition_query(@partition)}"} class="text-primary underline">Memories</.link><.link navigate={~p"/memory/profile?#{partition_query(@partition)}"} class="text-primary underline">Profile</.link><.link navigate={~p"/memory/actions?#{partition_query(@partition)}"} class="text-primary underline">Actions</.link></div>
    </div>
    """
  end

  defp load(socket, partition, domain, offset) do
    {stats, page} = Inventory.graph(partition, domain, offset: offset)
    relations = page.entries

    state =
      cond do
        not Config.pipeline_enabled?() or not Config.relation_classifier_enabled?() -> :disabled
        is_nil(Application.get_env(:backplane_memory, :llm_client)) -> :provider_unavailable
        empty?(stats) -> :empty
        true -> :ready
      end

    {:noreply,
     assign(socket,
       partition: partition,
       domain: domain,
       relations: relations,
       offset: offset,
       next_offset: page.next_offset,
       total: page.total,
       stats: stats,
       graph_state: state,
       error: nil
     )}
  end

  defp empty?(stats), do: stats.node_count_by_type == %{} and stats.edge_count_by_relation == %{}
  defp sorted(map), do: Enum.sort_by(map, fn {key, _} -> key end)
  defp domain(value) when value in ~w(knowledge lifecycle provenance), do: value
  defp domain(_), do: "knowledge"

  defp domain_query(partition, domain) do
    partition_query(partition) |> Map.put("domain", domain)
  end
end
