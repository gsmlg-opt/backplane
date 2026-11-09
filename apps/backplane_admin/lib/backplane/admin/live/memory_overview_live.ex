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
      <.memory_page_header title="Overview" subtitle="Memory records, captured events and sessions at a glance" />

      <.dm_alert :if={@llm_unset?} id="memory-llm-model-warning" variant="warning" title="提炼未启用">
        提炼未启用：未配置 memory.llm_model
      </.dm_alert>

      <.dm_alert :if={@distill_failed > 0} id="memory-distill-failed" variant="error" title="提炼失败">
        {@distill_failed} 个会话提炼失败，见 Sessions 页
      </.dm_alert>

      <.dm_alert :if={@distill_blocked > 0} id="memory-distill-blocked" variant="warning" title="提炼被阻塞">
        {@distill_blocked} 个会话提炼被阻塞，见 Sessions 页
      </.dm_alert>

      <div class="mt-4 grid gap-4 md:grid-cols-2">
        <.dm_card id="memory-overview-events" variant="bordered" padding="lg">
          <h2 class="text-sm text-on-surface-variant">Captured events (24h)</h2>
          <p id="memory-events-24h" class="text-2xl font-semibold">{@events_24h}</p>
        </.dm_card>
        <.dm_card id="memory-overview-sessions" variant="bordered" padding="lg">
          <h2 class="text-sm text-on-surface-variant">Open sessions</h2>
          <p id="memory-open-sessions" class="text-2xl font-semibold">{@open_sessions}</p>
        </.dm_card>
      </div>

      <h2 class="mt-6 font-semibold">Records by kind and status</h2>
      <p :if={@rows == []} id="memory-overview-no-records" class="text-sm text-on-surface-variant">No records yet.</p>
      <.dm_table :if={@rows != []} id="memory-record-counts" data={@rows} zebra>
        <:col :let={{kind, _s, _n}} label="Kind">{kind}</:col>
        <:col :let={{_k, status, _n}} label="Status">{status}</:col>
        <:col :let={{_k, _s, n}} label="Count">{n}</:col>
      </.dm_table>
    </div>
    """
  end
end
