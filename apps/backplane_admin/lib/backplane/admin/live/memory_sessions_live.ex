defmodule Backplane.Admin.MemorySessionsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  alias Backplane.Memory.AdminQueries

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, current_path: "/memory/sessions", sessions: AdminQueries.recent_sessions(100))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Sessions" subtitle="Recently active agent sessions" />
      <.memory_blank_state
        :if={@sessions == []}
        id="memory-sessions-empty"
        title="No sessions"
        description="No sessions have been captured yet."
      />
      <div :if={@sessions != []} class="min-w-0 w-full overflow-x-auto">
        <.dm_table id="memory-sessions-table" data={@sessions} hover zebra>
          <:col :let={s} label="Session"><span class="break-all">{s.session.session_id}</span></:col>
          <:col :let={s} label="Host">{s.session.host_id}</:col>
          <:col :let={s} label="Agent">{s.session.agent_id}</:col>
          <:col :let={s} label="Status">{s.session.status}</:col>
          <:col :let={s} label="Started"><.local_time datetime={s.session.started_at} format="short" /></:col>
          <:col :let={s} label="Ended"><.local_time datetime={s.session.ended_at} format="short" /></:col>
          <:col :let={s} label="Events">{s.event_count}</:col>
        </.dm_table>
      </div>
    </div>
    """
  end
end
