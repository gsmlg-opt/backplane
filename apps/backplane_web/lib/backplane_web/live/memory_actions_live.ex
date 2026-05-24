defmodule BackplaneWeb.MemoryActionsLive do
  @moduledoc "Coordination actions and active leases viewer."

  use BackplaneWeb, :live_view

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/memory/actions", actions: [], leases: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {actions, leases} = load_data()
    {:noreply, assign(socket, actions: actions, leases: leases)}
  end

  defp load_data do
    {
      safe_call(
        fn ->
          repo = Application.fetch_env!(:backplane_memory, :repo)
          alias BackplaneMemory.Coordination.Action

          repo.all(from(a in Action, order_by: [desc: a.inserted_at], limit: 50))
        end,
        []
      ),
      safe_call(
        fn ->
          repo = Application.fetch_env!(:backplane_memory, :repo)
          alias BackplaneMemory.Coordination.Lease
          now = DateTime.utc_now()

          repo.all(
            from(l in Lease,
              where: l.expires_at > ^now,
              order_by: [asc: l.expires_at]
            )
          )
        end,
        []
      )
    }
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_dt(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp action_description(%{metadata: %{"description" => d}}) when is_binary(d), do: d
  defp action_description(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Coordination Actions</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Active leases and recent coordination actions.
        </p>
      </div>

      <.dm_card variant="bordered" class="mb-4">
        <:title>Active Leases</:title>
        <div :if={@leases == []} class="text-on-surface-variant text-sm py-4">
          No active leases.
        </div>
        <div :if={@leases != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Action ID</th>
                <th class="text-left py-2 font-medium">Holder Agent</th>
                <th class="text-left py-2 font-medium">Expires</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={lease <- @leases} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono text-xs">{lease.action_id}</td>
                <td class="py-2 font-mono text-xs">{lease.holder_agent_id}</td>
                <td class="py-2 text-xs">{format_dt(lease.expires_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Recent Actions</:title>
        <div :if={@actions == []} class="text-on-surface-variant text-sm py-4">
          No actions recorded yet.
        </div>
        <div :if={@actions != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">ID</th>
                <th class="text-left py-2 font-medium">Status</th>
                <th class="text-left py-2 font-medium">Description</th>
                <th class="text-left py-2 font-medium">Created</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={action <- @actions} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono text-xs">{action.id}</td>
                <td class="py-2">
                  <.dm_badge variant="ghost">{action.status}</.dm_badge>
                </td>
                <td class="py-2 text-xs text-on-surface-variant">{action_description(action)}</td>
                <td class="py-2 text-xs">{format_dt(action.inserted_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>
    </div>
    """
  end
end
