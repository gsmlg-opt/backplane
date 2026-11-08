defmodule Backplane.Admin.MemoryEventsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  alias Backplane.Memory.AdminQueries

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, current_path: "/memory/events", events: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket),
      do: {:noreply, assign(socket, events: AdminQueries.recent_events(100))},
      else: {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Events" subtitle="Most recent captured events" />
      <.memory_blank_state
        :if={@events == []}
        id="memory-events-empty"
        title="No events"
        description="No events have been captured yet."
      />
      <div :if={@events != []} class="min-w-0 w-full overflow-x-auto">
        <.dm_table id="memory-events-table" data={@events} hover zebra>
          <:col :let={e} label="Type">{e.event_type}</:col>
          <:col :let={e} label="Host">{e.host_id}</:col>
          <:col :let={e} label="Agent">{e.agent_id}</:col>
          <:col :let={e} label="Integration">{e.integration}</:col>
          <:col :let={e} label="Session"><span class="break-all">{e.session_id}</span></:col>
          <:col :let={e} label="Time"><.local_time datetime={e.occurred_at} format="short" /></:col>
        </.dm_table>
      </div>
    </div>
    """
  end
end
