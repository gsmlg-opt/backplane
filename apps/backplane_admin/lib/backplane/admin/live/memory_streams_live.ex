defmodule Backplane.Admin.MemoryStreamsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  # Placeholder until the Memory admin pages are rebuilt on the global record store.
  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, current_path: "/memory/streams")}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Streams" subtitle="The capture stream browser is being rebuilt." />
      <.memory_blank_state
        id="memory-streams-placeholder"
        title="Streams unavailable"
        description="The capture stream browser is being rebuilt."
      />
    </div>
    """
  end
end
