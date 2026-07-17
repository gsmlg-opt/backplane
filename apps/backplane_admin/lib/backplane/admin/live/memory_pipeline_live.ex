defmodule Backplane.Admin.MemoryPipelineLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/memory/pipeline")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-pipeline-skeleton">
      <.memory_page_header
        title="Pipeline"
        subtitle="Guarded Memory V2 rollout controls"
      />
    </div>
    """
  end
end
