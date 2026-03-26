defmodule BackplaneWeb.ProjectsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Docs.Project
  alias Backplane.PubSubBroadcaster
  alias Backplane.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.docs_reindex_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/admin/projects",
       loading: true,
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_projects(socket)}
  end

  @impl true
  def handle_info({:completed, _}, socket), do: {:noreply, load_projects(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _, socket) do
    changeset = Project.changeset(%Project{}, %{})
    {:noreply, assign(socket, editing: :new, form: to_form(changeset))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    project = Repo.get!(Project, id)
    changeset = Project.changeset(project, %{})
    {:noreply, assign(socket, editing: project, form: to_form(changeset))}
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    case socket.assigns.editing do
      :new -> create_project(socket, params)
      %Project{} = project -> update_project(socket, project, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Repo.get(Project, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      project ->
        Repo.delete!(project)

        {:noreply,
         socket
         |> put_flash(:info, "Project #{id} deleted")
         |> assign(editing: nil, form: nil)
         |> load_projects()}
    end
  end

  def handle_event("reindex", %{"id" => id}, socket) do
    case Backplane.Jobs.Reindex.build_job(id) |> Oban.insert() do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Reindex job enqueued for #{id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue reindex job")}
    end
  end

  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      case socket.assigns.editing do
        :new -> Project.changeset(%Project{}, params)
        %Project{} = project -> Project.changeset(project, params)
      end

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
  end

  defp create_project(socket, params) do
    case %Project{} |> Project.changeset(params) |> Repo.insert() do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project #{project.id} created")
         |> assign(editing: nil, form: nil)
         |> load_projects()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_project(socket, project, params) do
    case project |> Project.changeset(params) |> Repo.update() do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project #{project.id} updated")
         |> assign(editing: nil, form: nil)
         |> load_projects()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp load_projects(socket) do
    projects =
      try do
        Repo.all(Project)
      rescue
        _ -> []
      end

    assign(socket, loading: false, projects: projects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Projects</h1>
        <button
          phx-click="new"
          class="rounded-md bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-600"
        >
          New Project
        </button>
      </div>

      <div :if={@editing} class="bg-gray-900 border border-gray-800 rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold text-white mb-4">
          {if @editing == :new, do: "New Project", else: "Edit Project"}
        </h2>
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Project ID</label>
            <input
              type="text"
              name="project[id]"
              value={@form[:id].value}
              disabled={@editing != :new}
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white disabled:opacity-50"
            />
            <.form_error field={@form[:id]} />
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Repository URL</label>
            <input
              type="text"
              name="project[repo]"
              value={@form[:repo].value}
              placeholder="https://github.com/org/repo"
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            />
            <.form_error field={@form[:repo]} />
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Branch/Ref</label>
            <input
              type="text"
              name="project[ref]"
              value={@form[:ref].value || "main"}
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Description</label>
            <input
              type="text"
              name="project[description]"
              value={@form[:description].value}
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="rounded-md bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-600"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel"
              class="rounded-md bg-gray-700 px-4 py-2 text-sm font-medium text-white hover:bg-gray-600"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <div :if={@projects == []} class="text-gray-400">
        No projects configured. Click "New Project" to add one.
      </div>

      <div class="space-y-4">
        <div
          :for={project <- @projects}
          class="bg-gray-900 border border-gray-800 rounded-lg p-4"
        >
          <div class="flex items-center justify-between">
            <div>
              <h3 class="text-sm font-medium text-white">{project.id}</h3>
              <p class="text-xs text-gray-400 mt-1">{project.repo} @ {project.ref}</p>
              <p :if={project.description} class="text-xs text-gray-500 mt-1">
                {project.description}
              </p>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-400">
                {if project.last_indexed_at,
                  do:
                    "Indexed: #{Calendar.strftime(project.last_indexed_at, "%Y-%m-%d %H:%M")}",
                  else: "Not indexed"}
              </span>
              <div class="flex gap-1">
                <button
                  phx-click="reindex"
                  phx-value-id={project.id}
                  class="rounded px-2 py-1 text-xs bg-blue-800 text-blue-200 hover:bg-blue-700"
                >
                  Reindex
                </button>
                <button
                  phx-click="edit"
                  phx-value-id={project.id}
                  class="rounded px-2 py-1 text-xs bg-gray-700 text-gray-200 hover:bg-gray-600"
                >
                  Edit
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={project.id}
                  data-confirm="Delete project #{project.id}? This will also delete all indexed chunks."
                  class="rounded px-2 py-1 text-xs bg-red-900 text-red-200 hover:bg-red-800"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp form_error(assigns) do
    ~H"""
    <div :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="text-xs text-red-400 mt-1">
      {msg}
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
