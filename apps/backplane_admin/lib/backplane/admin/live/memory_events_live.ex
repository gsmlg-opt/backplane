defmodule Backplane.Admin.MemoryEventsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/memory/events")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-events-skeleton">
      <.memory_page_header
        title="Events"
        subtitle="Authoritative Memory V2 event explorer"
      />
    </div>
    """
  end
end
