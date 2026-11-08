defmodule Backplane.Admin.MemoryOverviewLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  # Placeholder until the Memory admin pages are rebuilt on the global record store.
  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, current_path: "/memory")}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Overview" subtitle="Memory overview is being rebuilt for the global record store." />
      <.memory_blank_state
        id="memory-overview-placeholder"
        title="Overview unavailable"
        description="Memory overview is being rebuilt for the global record store."
      />
    </div>
    """
  end
end
