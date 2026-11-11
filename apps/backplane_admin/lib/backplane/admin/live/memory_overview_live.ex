defmodule Backplane.Admin.MemoryOverviewLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]

  alias Backplane.Memory.{AdminQueries, Config, Distillations}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory",
       rows: [],
       events_24h: 0,
       open_sessions: 0,
       llm_unset?: false,
       distill_failed: 0,
       distill_blocked: 0
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    rows =
      AdminQueries.record_counts()
      |> Enum.sort()
      |> Enum.map(fn {{kind, status}, n} -> {kind, status, n} end)

    counts = Distillations.counts()

    assign(socket,
      rows: rows,
      distill_failed: Map.get(counts, "failed", 0),
      distill_blocked: Map.get(counts, "blocked", 0),
      events_24h: AdminQueries.event_count_since(DateTime.add(DateTime.utc_now(), -86_400)),
      open_sessions: AdminQueries.open_session_count(),
      llm_unset?: is_nil(Config.llm_model())
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title={dgettext("navigation", "Overview")} subtitle={dgettext("admin", "Memory records, captured events and sessions at a glance")} />

      <.dm_alert :if={@llm_unset?} id="memory-llm-model-warning" variant="warning" title={dgettext("admin", "Distillation is off")}>
        {dgettext("admin", "Distillation is off: memory.llm_model is not configured.")}
      </.dm_alert>

      <.dm_alert :if={@distill_failed > 0} id="memory-distill-failed" variant="error" title={dgettext("admin", "Distillation failed")}>
        {dngettext("admin", "%{count} session failed to distill. See the Sessions page.", "%{count} sessions failed to distill. See the Sessions page.", @distill_failed)}
      </.dm_alert>

      <.dm_alert :if={@distill_blocked > 0} id="memory-distill-blocked" variant="warning" title={dgettext("admin", "Distillation blocked")}>
        {dngettext("admin", "%{count} session is blocked from distilling. See the Sessions page.", "%{count} sessions are blocked from distilling. See the Sessions page.", @distill_blocked)}
      </.dm_alert>

      <div class="mt-4 grid gap-4 md:grid-cols-2">
        <.dm_card id="memory-overview-events" variant="bordered" padding="lg">
          <h2 class="text-sm text-on-surface-variant">{dgettext("admin", "Captured events (24h)")}</h2>
          <p id="memory-events-24h" class="text-2xl font-semibold">{@events_24h}</p>
        </.dm_card>
        <.dm_card id="memory-overview-sessions" variant="bordered" padding="lg">
          <h2 class="text-sm text-on-surface-variant">{dgettext("admin", "Open sessions")}</h2>
          <p id="memory-open-sessions" class="text-2xl font-semibold">{@open_sessions}</p>
        </.dm_card>
      </div>

      <h2 class="mt-6 font-semibold">{dgettext("admin", "Records by kind and status")}</h2>
      <p :if={@rows == []} id="memory-overview-no-records" class="text-sm text-on-surface-variant">{dgettext("admin", "No records yet.")}</p>
      <.dm_table :if={@rows != []} id="memory-record-counts" data={@rows} zebra>
        <:col :let={{kind, _s, _n}} label={dgettext("admin", "Kind")}>{kind}</:col>
        <:col :let={{_k, status, _n}} label={dgettext("common", "Status")}>{status}</:col>
        <:col :let={{_k, _s, n}} label={dgettext("admin", "Count")}>{n}</:col>
      </.dm_table>
    </div>
    """
  end
end
