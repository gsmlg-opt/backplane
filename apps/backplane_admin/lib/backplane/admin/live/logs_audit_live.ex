defmodule Backplane.Admin.LogsAuditLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents

  alias Backplane.Audit

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/logs/audit",
       loading: true,
       tab: "tool_calls",
       filters: %{},
       time_range: %{since: default_since(), until: default_until()},
       tool_logs: [],
       skill_logs: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_audit_filters(params)
    time_range = parse_time_range(params)
    tab = params["tab"] || "tool_calls"

    {:noreply,
     assign(socket,
       loading: false,
       tab: tab,
       filters: filters,
       time_range: time_range,
       tool_logs: Audit.list_tool_call_logs(filters),
       skill_logs: Audit.list_skill_load_logs(filters)
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">Audit Logs</h1>
      <p class="mb-4 text-sm text-on-surface-variant">
        Persisted tool-call and skill-load audit records. Arguments are never stored — only hashes.
      </p>

      <.logs_nav current="/system/logs/audit" />

      <div class="mb-4 flex gap-2">
        <.dm_btn
          :for={tab <- ["tool_calls", "skill_loads"]}
          variant={if @tab == tab, do: "primary", else: nil}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab={tab}
        >
          {tab_label(tab)}
        </.dm_btn>
      </div>

      <form method="get" action={~p"/system/logs/audit"} class="mb-4 grid gap-3 md:grid-cols-4">
        <input type="hidden" name="tab" value={@tab} />
        <input type="hidden" name="since" value={DateTime.to_iso8601(@time_range.since)} />
        <input type="hidden" name="until" value={DateTime.to_iso8601(@time_range.until)} />
        <input
          class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
          name="tool_name"
          placeholder="Tool name"
          value={@filters[:tool_name] || ""}
        />
        <input
          class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
          name="skill_name"
          placeholder="Skill name"
          value={@filters[:skill_name] || ""}
        />
        <select class="rounded-md border border-outline bg-surface px-3 py-2 text-sm" name="status">
          <option value="" selected={@filters[:status] in [nil, ""]}>All statuses</option>
          <option value="ok" selected={@filters[:status] == "ok"}>ok</option>
          <option value="error" selected={@filters[:status] == "error"}>error</option>
        </select>
        <.dm_btn type="submit" variant="primary" size="sm">Filter</.dm_btn>
      </form>

      <div :if={@tab == "tool_calls"}>
        <div :if={@tool_logs == []}>
          <.empty_state title="No tool audit records" />
        </div>
        <.dm_table :if={@tool_logs != []} id="audit-tool-table" data={@tool_logs} hover zebra>
          <:col :let={row} label="Tool">
            <span class="font-mono text-xs">{row.tool_name}</span>
          </:col>
          <:col :let={row} label="Client">{row.client_name || "-"}</:col>
          <:col :let={row} label="Status">
            <.dm_badge variant={outcome_badge_variant(row.status)} size="sm">{row.status}</.dm_badge>
          </:col>
          <:col :let={row} label="Args hash">
            <span class="font-mono text-xs">{row.arguments_hash || "-"}</span>
          </:col>
          <:col :let={row} label="Error">
            <span class="max-w-xs truncate text-xs">{bounded_error(row.error_message) || "-"}</span>
          </:col>
          <:col :let={row} label="Recorded">
            <.local_time datetime={row.inserted_at} format="short" />
          </:col>
        </.dm_table>
      </div>

      <div :if={@tab == "skill_loads"}>
        <div :if={@skill_logs == []}>
          <.empty_state title="No skill load audit records" />
        </div>
        <.dm_table :if={@skill_logs != []} id="audit-skill-table" data={@skill_logs} hover zebra>
          <:col :let={row} label="Skill">{row.skill_name}</:col>
          <:col :let={row} label="Client">{row.client_name || "-"}</:col>
          <:col :let={row} label="Dependencies">{length(row.loaded_deps || [])}</:col>
          <:col :let={row} label="Recorded">
            <.local_time datetime={row.inserted_at} format="short" />
          </:col>
        </.dm_table>
      </div>
    </div>
    """
  end

  defp tab_label("tool_calls"), do: "Tool Calls"
  defp tab_label("skill_loads"), do: "Skill Loads"
  defp tab_label(other), do: other
end
