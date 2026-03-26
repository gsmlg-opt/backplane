defmodule BackplaneWeb.DocsLive do
  use BackplaneWeb, :live_view

  import Ecto.Query
  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Backplane.PubSubBroadcaster.subscribe(Backplane.PubSubBroadcaster.docs_reindex_topic())
    end

    {:ok, assign(socket, current_path: "/admin/docs", loading: true)}
  end

  @impl true
  def handle_info({:completed, _payload}, socket) do
    {:noreply, load_docs(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_docs(socket)}
  end

  @impl true
  def handle_event("reindex", %{"id" => id}, socket) do
    case Backplane.Jobs.Reindex.new(%{project_id: id}) |> Oban.insert() do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Reindex job enqueued for #{id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue reindex job")}
    end
  end

  defp load_docs(socket) do
    projects = safe_call(fn -> Repo.all(Project) end, [])

    chunk_counts =
      safe_call(
        fn ->
          DocChunk
          |> group_by([c], c.project_id)
          |> select([c], {c.project_id, count(c.id)})
          |> Repo.all()
          |> Map.new()
        end,
        %{}
      )

    assign(socket, loading: false, projects: projects, chunk_counts: chunk_counts)
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
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-400">
                Chunks: {Map.get(@chunk_counts, project.id, 0)}
              </span>
              <span class="text-xs text-gray-400">
                {if project.last_indexed_at, do: "Indexed: #{Calendar.strftime(project.last_indexed_at, "%Y-%m-%d %H:%M")}", else: "Not indexed"}
              </span>
              <button
                phx-click="reindex"
                phx-value-id={project.id}
                class="rounded px-2 py-1 text-xs bg-blue-800 text-blue-200 hover:bg-blue-700"
              >
                Reindex
              </button>
            </div>
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
