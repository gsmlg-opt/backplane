defmodule BackplaneWeb.SkillUpstreamLive do
  @moduledoc """
  Manage upstream skill sync sources (e.g. GitHub repos).
  Add sources, browse remote skills, select which to sync.
  """

  use BackplaneWeb, :live_view

  alias Backplane.Skills.SkillSources
  alias Backplane.Skills.SkillSource

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/skills/upstream",
       loading: true,
       sources: [],
       selected_source: nil,
       remote_skills: [],
       remote_loading: false,
       remote_error: nil,
       selected_remote: MapSet.new(),
       syncing: false,
       form: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(selected_source: nil, form: nil, current_path: "/admin/skills/upstream")
         |> load_sources()}

      :new ->
        changeset = SkillSource.changeset(%SkillSource{}, %{})

        {:noreply,
         assign(socket,
           form: to_form(changeset),
           selected_source: nil,
           current_path: "/admin/skills/upstream"
         )}

      :show ->
        case SkillSources.get(params["id"]) do
          {:ok, source} ->
            {:noreply,
             socket
             |> assign(
               selected_source: source,
               form: nil,
               remote_skills: [],
               remote_loading: false,
               remote_error: nil,
               selected_remote: MapSet.new(),
               current_path: "/admin/skills/upstream"
             )
             |> load_sources()}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Source not found")
             |> push_patch(to: ~p"/admin/skills/upstream")}
        end
    end
  end

  @impl true
  def handle_event("save-source", %{"skill_source" => params}, socket) do
    case SkillSources.create(params) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Source added")
         |> push_patch(to: ~p"/admin/skills/upstream")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete-source", %{"id" => id}, socket) do
    case SkillSources.get(id) do
      {:ok, source} ->
        case SkillSources.delete(source) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Source deleted")
             |> assign(selected_source: nil)
             |> load_sources()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete source")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}
    end
  end

  def handle_event("fetch-remote", %{"id" => id}, socket) do
    case SkillSources.get(id) do
      {:ok, source} ->
        socket = assign(socket, remote_loading: true, remote_error: nil, selected_source: source)
        send(self(), {:fetch_remote, source})
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}
    end
  end

  def handle_event("toggle-remote", %{"slug" => slug}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_remote, slug) do
        MapSet.delete(socket.assigns.selected_remote, slug)
      else
        MapSet.put(socket.assigns.selected_remote, slug)
      end

    {:noreply, assign(socket, selected_remote: selected)}
  end

  def handle_event("select-all-remote", _params, socket) do
    all = socket.assigns.remote_skills |> Enum.map(& &1[:slug]) |> MapSet.new()
    {:noreply, assign(socket, selected_remote: all)}
  end

  def handle_event("clear-remote-selection", _params, socket) do
    {:noreply, assign(socket, selected_remote: MapSet.new())}
  end

  def handle_event("sync-selected", _params, socket) do
    source = socket.assigns.selected_source
    selected_slugs = socket.assigns.selected_remote

    entries =
      socket.assigns.remote_skills
      |> Enum.filter(fn skill -> MapSet.member?(selected_slugs, skill[:slug]) end)

    if source && entries != [] do
      socket = assign(socket, syncing: true)

      case SkillSources.sync_skills(source, entries) do
        {:ok, result} ->
          {:noreply,
           socket
           |> put_flash(:info, "Synced #{result.synced} skill(s)")
           |> assign(syncing: false, selected_remote: MapSet.new())
           |> load_sources()}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Sync failed: #{inspect(reason)}")
           |> assign(syncing: false)}
      end
    else
      {:noreply, put_flash(socket, :error, "No skills selected")}
    end
  end

  @impl true
  def handle_info({:fetch_remote, source}, socket) do
    case SkillSources.list_remote_skills(source) do
      {:ok, skills} ->
        {:noreply,
         assign(socket,
           remote_skills: skills,
           remote_loading: false,
           remote_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           remote_skills: [],
           remote_loading: false,
           remote_error: inspect(reason)
         )}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp load_sources(socket) do
    sources = safe_call(fn -> SkillSources.list() end, [])
    assign(socket, sources: sources, loading: false)
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp format_dt(nil), do: "Never"

  defp format_dt(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_dt(_), do: "-"

  defp status_variant("success"), do: "success"
  defp status_variant("partial"), do: "warning"
  defp status_variant("failed"), do: "error"
  defp status_variant("pending"), do: "info"
  defp status_variant(_), do: "ghost"

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Upstream Sources</h1>
          <p class="text-sm text-on-surface-variant mt-1">
            Configure GitHub repositories to sync skills from.
          </p>
        </div>
        <.link :if={@live_action != :new} patch={~p"/admin/skills/upstream/new"}>
          <.dm_btn variant="primary" size="sm">Add Source</.dm_btn>
        </.link>
      </div>

      <%!-- New source form --%>
      <.dm_card :if={@live_action == :new} variant="bordered" class="mb-6">
        <:title>Add Upstream Source</:title>
        <.form for={@form} phx-submit="save-source" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                field={@form[:name]}
                label="Name"
                placeholder="My Skills Repo"
                required
              />
            </div>
            <div>
              <.dm_input
                field={@form[:source_type]}
                label="Type"
                value="github"
                disabled
              />
            </div>
            <div class="sm:col-span-2">
              <.dm_input
                field={@form[:url]}
                label="Repository URL"
                placeholder="https://github.com/org/skills-repo"
                required
              />
            </div>
            <div>
              <.dm_input field={@form[:branch]} label="Branch" placeholder="main" />
            </div>
            <div>
              <.dm_input field={@form[:path_prefix]} label="Path Prefix" placeholder="skills/" />
            </div>
          </div>
          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary" size="sm">Create</.dm_btn>
            <.link patch={~p"/admin/skills/upstream"} class="no-underline">
              <.dm_btn type="button" size="sm">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>

      <%!-- Sources table --%>
      <div :if={@sources == [] and @live_action == :index} class="text-on-surface-variant py-12 text-center">
        No upstream sources configured yet.
      </div>

      <div :if={@sources != []} class="space-y-4 mb-6">
        <.dm_card :for={source <- @sources} variant="bordered">
          <:title>
            <div class="flex w-full items-center justify-between gap-4">
              <div class="flex items-center gap-3">
                <span class="font-medium">{source.name}</span>
                <.dm_badge variant="ghost" size="sm">{source.source_type}</.dm_badge>
                <.dm_badge
                  :if={source.last_sync_status}
                  variant={status_variant(source.last_sync_status)}
                  size="sm"
                >
                  {source.last_sync_status}
                </.dm_badge>
              </div>
              <div class="flex items-center gap-2">
                <.dm_btn
                  size="xs"
                  variant="primary"
                  phx-click="fetch-remote"
                  phx-value-id={source.id}
                >
                  Fetch Skills
                </.dm_btn>
                <.dm_btn
                  size="xs"
                  variant="error"
                  data-confirm={"Delete source #{source.name}?"}
                  phx-click="delete-source"
                  phx-value-id={source.id}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </:title>
          <div class="text-sm text-on-surface-variant space-y-1">
            <div>
              <span class="font-medium">URL:</span>
              <a href={source.url} target="_blank" class="ml-1">{source.url}</a>
            </div>
            <div>
              <span class="font-medium">Branch:</span>
              <span class="ml-1 font-mono">{source.branch}</span>
              <span class="ml-3 font-medium">Path:</span>
              <span class="ml-1 font-mono">{source.path_prefix}</span>
            </div>
            <div>
              <span class="font-medium">Last synced:</span>
              <span class="ml-1">{format_dt(source.last_synced_at)}</span>
            </div>
            <div :if={source.last_sync_error} class="text-error text-xs">
              Error: {source.last_sync_error}
            </div>
          </div>
        </.dm_card>
      </div>

      <%!-- Remote skills panel --%>
      <div :if={@remote_loading} class="text-center py-8 text-on-surface-variant">
        <div class="text-sm">Fetching skills from upstream source…</div>
      </div>

      <div :if={@remote_error} class="mb-4">
        <.dm_card variant="bordered" class="border-error/50">
          <div class="text-sm text-error">
            Failed to fetch remote skills: {@remote_error}
          </div>
        </.dm_card>
      </div>

      <.dm_card
        :if={@remote_skills != [] and not @remote_loading and @selected_source}
        variant="bordered"
      >
        <:title>
          <div class="flex items-center justify-between w-full">
            <div class="flex items-center gap-2">
              <span>
                Available Skills from {@selected_source.name}
              </span>
              <.dm_badge variant="neutral" size="sm">{length(@remote_skills)}</.dm_badge>
            </div>
            <div class="flex items-center gap-2">
              <.dm_btn
                :if={MapSet.size(@selected_remote) > 0}
                size="xs"
                variant="primary"
                phx-click="sync-selected"
                disabled={@syncing}
              >
                {if @syncing, do: "Syncing…", else: "Sync #{MapSet.size(@selected_remote)} Selected"}
              </.dm_btn>
              <.dm_btn size="xs" phx-click="select-all-remote">Select All</.dm_btn>
              <.dm_btn
                :if={MapSet.size(@selected_remote) > 0}
                size="xs"
                phx-click="clear-remote-selection"
              >
                Clear
              </.dm_btn>
            </div>
          </div>
        </:title>

        <div class="divide-y divide-outline-variant/40">
          <div
            :for={skill <- @remote_skills}
            class="flex items-center gap-3 py-2"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected_remote, skill[:slug])}
              phx-click="toggle-remote"
              phx-value-slug={skill[:slug]}
              class="checkbox checkbox-sm"
            />
            <div class="min-w-0 flex-1">
              <div class="font-medium text-sm">{skill[:name]}</div>
              <div class="text-xs text-on-surface-variant truncate">
                {skill[:description] || skill[:slug]}
              </div>
            </div>
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={tag <- skill[:tags] || []} variant="ghost" size="sm">
                {tag}
              </.dm_badge>
            </div>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end
end
