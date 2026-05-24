defmodule BackplaneWeb.MemoryGraphLive do
  @moduledoc "Entity knowledge graph browser with BFS search."

  use BackplaneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    graph_stats = safe_call(fn -> BackplaneMemory.Graph.stats() end, %{nodes: 0, edges: 0})

    {:ok,
     assign(socket,
       current_path: "/admin/memory/graph",
       graph_stats: graph_stats,
       search_query: "",
       results: [],
       searched: false
     )}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) when byte_size(query) > 0 do
    results = run_search(query)
    {:noreply, assign(socket, search_query: query, results: results, searched: true)}
  end

  def handle_event("search", _params, socket) do
    {:noreply, assign(socket, results: [], searched: false)}
  end

  defp run_search(name) do
    safe_call(
      fn ->
        repo = Application.fetch_env!(:backplane_memory, :repo)
        BackplaneMemory.Graph.BFS.query(name, repo, [])
      end,
      []
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp edge_count(%{edges: edges}) when is_list(edges), do: length(edges)
  defp edge_count(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Knowledge Graph</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Search entities in the agent knowledge graph using BFS traversal.
        </p>
      </div>

      <div class="grid grid-cols-2 gap-3 mb-6">
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Nodes</div>
          <div class="text-3xl font-bold">{@graph_stats[:nodes] || 0}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Edges</div>
          <div class="text-3xl font-bold">{@graph_stats[:edges] || 0}</div>
        </.dm_card>
      </div>

      <.dm_card variant="bordered" class="mb-4">
        <.form for={%{}} phx-submit="search" class="flex items-center gap-3">
          <input
            type="text"
            name="q"
            value={@search_query}
            placeholder="Entity name..."
            class="dm-input flex-1"
            phx-debounce="300"
          />
          <.dm_btn type="submit">Search</.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@searched} variant="bordered">
        <div :if={@results == []} class="text-on-surface-variant text-sm py-4">
          No entities found for "{@search_query}".
        </div>
        <div :if={@results != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Entity Type</th>
                <th class="text-left py-2 font-medium">Name</th>
                <th class="text-right py-2 font-medium">Depth</th>
                <th class="text-right py-2 font-medium">Edges</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={result <- @results} class="border-b border-outline-variant/40">
                <td class="py-2">
                  <.dm_badge variant="ghost">{result.node.entity_type}</.dm_badge>
                </td>
                <td class="py-2 font-medium">{result.node.name}</td>
                <td class="py-2 text-right">{result.depth}</td>
                <td class="py-2 text-right">{edge_count(result)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>
    </div>
    """
  end
end
