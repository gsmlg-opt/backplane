defmodule Backplane.Admin.MemoryEventsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  # Placeholder until the Memory admin pages are rebuilt on the global record store.
  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, current_path: "/memory/events")}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Events" subtitle="The captured event browser is being rebuilt." />
      <.memory_blank_state
        id="memory-events-placeholder"
        title="Events unavailable"
        description="The captured event browser is being rebuilt."
      />
    </div>
    """
  end
end
