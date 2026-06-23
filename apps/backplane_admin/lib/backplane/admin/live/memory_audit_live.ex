defmodule Backplane.Admin.MemoryAuditLive do
  @moduledoc "Paginated audit log for memory system operations."

  use Backplane.Admin, :live_view

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/memory/audit",
       entries: [],
       page: 1,
       page_size: @page_size
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    entries =
      safe_call(
        fn -> BackplaneMemory.Audit.list(limit: @page_size, offset: (page - 1) * @page_size) end,
        []
      )

    {:noreply, assign(socket, entries: entries, page: page)}
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp format_dt(nil), do: ""
  defp format_dt(dt) do
    assigns = %{dt: dt}
    ~H"""
    <.local_time datetime={@dt} />
    """
  end

  defp format_target_ids(ids) when is_list(ids), do: Enum.join(ids, ", ")
  defp format_target_ids(nil), do: ""

  defp format_target_ids(other) do
    safe_call(fn -> Jason.encode!(other) end, inspect(other))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Audit Log</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Memory system operations audit trail. Page {@page}.
        </p>
      </div>

      <.dm_card variant="bordered">
        <div :if={@entries == []} class="text-on-surface-variant text-sm py-4">
          No audit entries recorded yet.
        </div>
        <div :if={@entries != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Operation</th>
                <th class="text-left py-2 font-medium">Actor</th>
                <th class="text-left py-2 font-medium">Targets</th>
                <th class="text-left py-2 font-medium">Created</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @entries} class="border-b border-outline-variant/40">
                <td class="py-2">
                  <.dm_badge variant="ghost">{entry.operation}</.dm_badge>
                </td>
                <td class="py-2 font-mono text-xs">{entry.actor}</td>
                <td class="py-2 text-xs text-on-surface-variant">{format_target_ids(entry.target_ids)}</td>
                <td class="py-2 text-xs">{format_dt(entry.created_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <div class="flex items-center justify-between mt-4 text-sm">
        <div class="text-on-surface-variant">Page {@page}</div>
        <div class="flex items-center gap-2">
          <.link :if={@page > 1} patch={~p"/admin/memory/audit?#{%{page: @page - 1}}"}>
            <.dm_btn size="xs">Previous</.dm_btn>
          </.link>
          <.link :if={length(@entries) == @page_size} patch={~p"/admin/memory/audit?#{%{page: @page + 1}}"}>
            <.dm_btn size="xs">Next</.dm_btn>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
