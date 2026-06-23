defmodule Backplane.Admin.MemoryOverviewLive do
  @moduledoc "Memory overview: aggregate stats across memories, graph, and sessions."

  use Backplane.Admin, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/memory",
       memory_stats: [],
       graph_stats: %{nodes: 0, edges: 0},
       total_active: 0,
       total_deleted: 0
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_stats(socket)}
  end

  defp load_stats(socket) do
    memory_stats = safe_call(fn -> BackplaneMemory.Memory.stats() end, [])
    total_active = safe_call(fn -> BackplaneMemory.Memory.count([]) end, 0)
    total_all = safe_call(fn -> BackplaneMemory.Memory.count(include_deleted: true) end, 0)
    graph_stats = safe_call(fn -> BackplaneMemory.Graph.stats() end, %{nodes: 0, edges: 0})

    assign(socket,
      memory_stats: memory_stats,
      total_active: total_active,
      total_deleted: max(total_all - total_active, 0),
      graph_stats: graph_stats
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp count_for(stats, type) do
    case Enum.find(stats, &(&1.memory_type == type)) do
      nil -> 0
      %{count: c} -> c
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Memory Overview</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Aggregate statistics for the agent memory system.
        </p>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Active Memories</div>
          <div class="text-3xl font-bold">{@total_active}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Deleted Memories</div>
          <div class="text-3xl font-bold">{@total_deleted}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Graph Nodes</div>
          <div class="text-3xl font-bold">{@graph_stats[:nodes] || 0}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Graph Edges</div>
          <div class="text-3xl font-bold">{@graph_stats[:edges] || 0}</div>
        </.dm_card>
      </div>

      <.dm_card variant="bordered">
        <:title>Memory by Type</:title>
        <div :if={@memory_stats == []} class="text-on-surface-variant text-sm py-4">
          No memories yet.
        </div>
        <div :if={@memory_stats != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Type</th>
                <th class="text-right py-2 font-medium">Count</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={type <- ~w(working episodic semantic procedural)} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono">{type}</td>
                <td class="py-2 text-right">{count_for(@memory_stats, type)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <div class="mt-4 grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.link navigate={~p"/admin/memory/browse"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Browse</div>
            <div class="text-xs text-on-surface-variant mt-1">Filter and manage memories</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/memory/observations"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Observations</div>
            <div class="text-xs text-on-surface-variant mt-1">Recent tool call observations</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/memory/sessions"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Sessions</div>
            <div class="text-xs text-on-surface-variant mt-1">Agent session history</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/memory/graph"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Graph</div>
            <div class="text-xs text-on-surface-variant mt-1">Entity relationship graph</div>
          </.dm_card>
        </.link>
      </div>
    </div>
    """
  end
end
