defmodule Backplane.Admin.MemoryStatsLive do
  @moduledoc "Memory observability: counts by type, scope, and totals (deleted vs active)."

  use Backplane.Admin, :live_view

  alias BackplaneMemory.Memory

  @memory_types ~w(working episodic semantic procedural)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/memory/stats",
       loading: true,
       type_counts: [],
       scope_counts: [],
       total_active: 0,
       total_deleted: 0
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_stats(socket)}
  end

  defp load_stats(socket) do
    type_counts = safe_call(fn -> Memory.stats() end, [])
    scope_counts = safe_call(fn -> Memory.scope_stats() end, [])
    total_active = safe_call(fn -> Memory.count([]) end, 0)
    total_all = safe_call(fn -> Memory.count(include_deleted: true) end, 0)

    assign(socket,
      loading: false,
      type_counts: type_counts,
      scope_counts: scope_counts,
      total_active: total_active,
      total_deleted: max(total_all - total_active, 0)
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp count_for(type_counts, type) do
    case Enum.find(type_counts, &(&1.memory_type == type)) do
      nil -> 0
      %{count: c} -> c
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :memory_types, @memory_types)

    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Memory Stats</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Counts by 4-tier consolidation (working / episodic / semantic / procedural) and scope.
        </p>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-6 gap-3 mb-6">
        <.dm_stat title="Active" value={to_string(@total_active)} />
        <.dm_stat title="Deleted" value={to_string(@total_deleted)} />
        <.dm_stat
          :for={t <- @memory_types}
          title={String.capitalize(t)}
          value={to_string(count_for(@type_counts, t))}
        />
      </div>

      <.dm_card variant="bordered">
        <:title>By scope</:title>
        <div :if={@scope_counts == []} class="text-on-surface-variant text-sm">
          No memories yet.
        </div>
        <div :if={@scope_counts != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Scope</th>
                <th class="text-right py-2 font-medium">Count</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @scope_counts} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono">{row.scope}</td>
                <td class="py-2 text-right">{row.count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>
    </div>
    """
  end
end
