defmodule BackplaneWeb.DocsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Docs.Project
  alias Backplane.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/docs", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    projects = safe_call(fn -> Repo.all(Project) end, [])
    {:noreply, assign(socket, loading: false, projects: projects)}
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold text-white mb-6">Documentation Projects</h1>

      <div :if={@projects == []} class="text-gray-400">
        No projects configured. Add [[projects]] sections to your backplane.toml.
      </div>

      <div class="space-y-4">
        <div
          :for={project <- @projects}
          class="bg-gray-900 border border-gray-800 rounded-lg p-4"
        >
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium text-white">{project.id}</h3>
            <span class="text-xs text-gray-400">
              {if project.last_indexed_at, do: "Indexed: #{Calendar.strftime(project.last_indexed_at, "%Y-%m-%d %H:%M")}", else: "Not indexed"}
            </span>
          </div>
          <p class="text-xs text-gray-400 mt-1">
            {project.repo} @ {project.ref}
          </p>
          <p :if={project.description} class="text-xs text-gray-500 mt-1">
            {project.description}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
