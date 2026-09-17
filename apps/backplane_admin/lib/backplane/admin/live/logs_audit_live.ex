defmodule Backplane.Admin.LogsAuditLive do
  use Backplane.Admin, :live_view
  import Backplane.Admin.LogsComponents
  alias Backplane.Admin.Audit

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/logs/audit",
       records: [],
       filters: %{},
       next_cursor: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    time = parse_time_range(params)

    filters =
      Map.merge(time, Map.new([:action, :target_type, :target_id], &{&1, params[to_string(&1)]}))

    {:noreply, load_page(socket, filters, nil)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    {:noreply, load_page(socket, socket.assigns.filters, socket.assigns.next_cursor)}
  end

  defp load_page(socket, filters, cursor) do
    rows = Audit.list(filters, limit: 51, cursor: cursor)
    records = Enum.take(rows, 50)
    last = List.last(records)
    next_cursor = if length(rows) > 50, do: {last.inserted_at, last.id}, else: nil
    assign(socket, filters: filters, records: records, next_cursor: next_cursor)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-4 text-2xl font-bold">Audit Logs</h1>
      <form method="get" action={~p"/system/logs/audit"} class="mb-4 grid gap-3 md:grid-cols-3">
        <.dm_input name="action" label="Action" value={@filters[:action] || ""} />
        <.dm_input name="target_type" label="Target type" value={@filters[:target_type] || ""} />
        <.dm_input name="target_id" label="Target ID" value={@filters[:target_id] || ""} />
        <.dm_input name="since" label="Since" value={DateTime.to_iso8601(@filters.since)} />
        <.dm_input name="until" label="Until" value={DateTime.to_iso8601(@filters.until)} />
        <.dm_btn type="submit" variant="primary" size="sm">Filter</.dm_btn>
      </form>
      <.empty_state :if={@records == []} title="No admin operations found" />
      <.dm_table :if={@records != []} id="admin-audit-table" data={@records} hover zebra>
        <:col :let={row} label="Actor">{row.actor}</:col>
        <:col :let={row} label="Source">{row.source}</:col>
        <:col :let={row} label="Action">{row.action}</:col>
        <:col :let={row} label="Target type">{row.target_type}</:col>
        <:col :let={row} label="Target ID">{row.target_id || "-"}</:col>
        <:col :let={row} label="Recorded">
          <.local_time datetime={row.inserted_at} format="short" />
        </:col>
      </.dm_table>
      <.dm_btn :if={@next_cursor} phx-click="next_page" size="sm" class="mt-4">Next page</.dm_btn>
    </div>
    """
  end
end
