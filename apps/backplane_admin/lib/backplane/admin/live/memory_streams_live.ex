defmodule Backplane.Admin.MemoryStreamsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/memory/streams")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-streams-skeleton">
      <.memory_page_header
        title="Streams"
        subtitle="Authoritative Memory V2 stream inventory"
      />
    </div>
    """
  end
end
