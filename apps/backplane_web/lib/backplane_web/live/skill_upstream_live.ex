defmodule BackplaneWeb.SkillUpstreamLive do
  @moduledoc """
  Manage upstream skill sync sources (e.g. GitHub repos).
  - Index: lists sources with [Sync] and [Edit] actions.
  - New: standalone page with creation form.
  - Edit: full edit form, remote skill selector, sync tags, delete.
  """

  use BackplaneWeb, :live_view

  alias Backplane.Skills.SkillSources
  alias Backplane.Skills.SkillSource

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/admin/skills/upstream",
       loading: true,
       sources: [],
       form: nil,
       editing_source: nil,
       remote_skills: [],
       remote_loading: false,
       remote_error: nil,
       selected_skills: MapSet.new(),
       syncing_id: nil,
       tag_input: "",
       show_import: false
     )
     |> allow_upload(:import_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(
           form: nil,
           editing_source: nil,
           remote_skills: [],
           remote_loading: false,
           remote_error: nil,
           current_path: "/admin/skills/upstream"
         )
         |> load_sources()}

      :new ->
        changeset = SkillSource.changeset(%SkillSource{}, %{})

        {:noreply,
         assign(socket,
           form: to_form(changeset, as: :skill_source),
           editing_source: nil,
           tag_input: "",
           current_path: "/admin/skills/upstream"
         )}

      :show ->
        case SkillSources.get(params["id"]) do
          {:ok, source} ->
            {:noreply,
             socket
             |> assign(
               editing_source: source,
               form: nil,
               current_path: "/admin/skills/upstream"
             )
             |> load_sources()}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Source not found")
             |> push_patch(to: ~p"/admin/skills/upstream")}
        end

      :edit ->
        case SkillSources.get(params["id"]) do
          {:ok, source} ->
            changeset = SkillSource.changeset(source, %{})
            selected = MapSet.new(source.selected_skills || [])

            {:noreply,
             socket
             |> assign(
               editing_source: source,
               form: to_form(changeset, as: :skill_source),
               selected_skills: selected,
               tag_input: Enum.join(source.sync_tags || [], ", "),
               remote_skills: [],
               remote_loading: true,
               remote_error: nil,
               current_path: "/admin/skills/upstream"
             )
             |> tap(fn _ -> send(self(), {:fetch_remote_for_edit, source}) end)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Source not found")
             |> push_patch(to: ~p"/admin/skills/upstream")}
        end
    end
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("save-source", %{"skill_source" => params}, socket) do
    tags = parse_tags(socket.assigns.tag_input)
    params = Map.put(params, "sync_tags", tags)

    case SkillSources.create(params) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Source added")
         |> push_navigate(to: ~p"/admin/skills/upstream")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :skill_source))}
    end
  end

  def handle_event("update-source", %{"skill_source" => params}, socket) do
    source = socket.assigns.editing_source

    # Merge selected_skills and sync_tags from live assigns
    selected = socket.assigns.selected_skills |> MapSet.to_list()
    tags = parse_tags(socket.assigns.tag_input)

    attrs =
      params
      |> Map.put("selected_skills", selected)
      |> Map.put("sync_tags", tags)

    case SkillSources.update(source, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Source '#{updated.name}' updated")
         |> push_navigate(to: ~p"/admin/skills/upstream")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :skill_source))}
    end
  end

  def handle_event("validate-source", %{"skill_source" => params}, socket) do
    source = socket.assigns.editing_source || %SkillSource{}

    changeset =
      source
      |> SkillSource.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :skill_source))}
  end

  def handle_event("delete-source", %{"id" => id}, socket) do
    case SkillSources.get(id) do
      {:ok, source} ->
        case SkillSources.delete(source) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Source deleted")
             |> push_navigate(to: ~p"/admin/skills/upstream")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete source")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}
    end
  end

  def handle_event("sync-source", %{"id" => id}, socket) do
    case SkillSources.get(id) do
      {:ok, source} ->
        socket = assign(socket, syncing_id: id)
        send(self(), {:do_sync, source})
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}
    end
  end

  def handle_event("sync-all", _params, socket) do
    socket = assign(socket, syncing_id: :all)
    send(self(), :do_sync_all)
    {:noreply, socket}
  end

  def handle_event("export-sources", _params, socket) do
    sources = socket.assigns.sources

    export_data =
      Enum.map(sources, fn s ->
        %{
          name: s.name,
          source_type: s.source_type,
          url: s.url,
          branch: s.branch,
          path_prefix: s.path_prefix,
          enabled: s.enabled,
          selected_skills: s.selected_skills,
          sync_tags: s.sync_tags
        }
      end)

    json = Jason.encode!(export_data, pretty: true)
    filename = "skill_sources_#{Date.utc_today()}.json"

    {:noreply,
     socket
     |> push_event("download", %{content: json, filename: filename, content_type: "application/json"})}
  end

  def handle_event("toggle-import", _params, socket) do
    {:noreply, assign(socket, show_import: !socket.assigns.show_import)}
  end

  def handle_event("import-sources", _params, socket) do
    consumed =
      consume_uploaded_entries(socket, :import_file, fn %{path: path}, _entry ->
        content = File.read!(path)
        {:ok, Jason.decode!(content)}
      end)

    case consumed do
      [entries] when is_list(entries) ->
        results =
          Enum.map(entries, fn entry ->
            attrs = %{
              "name" => entry["name"],
              "source_type" => entry["source_type"] || "github",
              "url" => entry["url"],
              "branch" => entry["branch"] || "main",
              "path_prefix" => entry["path_prefix"] || "skills/",
              "enabled" => Map.get(entry, "enabled", true),
              "selected_skills" => entry["selected_skills"] || [],
              "sync_tags" => entry["sync_tags"] || []
            }

            SkillSources.create(attrs)
          end)

        created = Enum.count(results, &match?({:ok, _}, &1))
        failed = Enum.count(results, &match?({:error, _}, &1))

        msg =
          if failed > 0,
            do: "Imported #{created} source(s), #{failed} skipped (duplicate or invalid)",
            else: "Imported #{created} source(s)"

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> assign(show_import: false)
         |> load_sources()}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid file. Expected a JSON array of sources.")}
    end
  rescue
    e ->
      {:noreply, put_flash(socket, :error, "Import failed: #{Exception.message(e)}")}
  end

  def handle_event("validate-import", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle-skill", %{"slug" => slug}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_skills, slug) do
        MapSet.delete(socket.assigns.selected_skills, slug)
      else
        MapSet.put(socket.assigns.selected_skills, slug)
      end

    {:noreply, assign(socket, selected_skills: selected)}
  end

  def handle_event("select-all-skills", _params, socket) do
    all = socket.assigns.remote_skills |> Enum.map(& &1[:slug]) |> MapSet.new()
    {:noreply, assign(socket, selected_skills: all)}
  end

  def handle_event("clear-skills", _params, socket) do
    {:noreply, assign(socket, selected_skills: MapSet.new())}
  end

  def handle_event("update-tags", %{"value" => value}, socket) do
    {:noreply, assign(socket, tag_input: value)}
  end

  def handle_event("refresh-remote", _params, socket) do
    source = socket.assigns.editing_source

    if source do
      socket = assign(socket, remote_loading: true, remote_error: nil)
      send(self(), {:fetch_remote_for_edit, source})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Info handlers ───────────────────────────────────────────────────────────

  @impl true
  def handle_info({:do_sync, source}, socket) do
    case SkillSources.sync_from_source(source) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Synced #{result.synced} skill(s)")
         |> assign(syncing_id: nil)
         |> load_sources()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Sync failed: #{inspect(reason)}")
         |> assign(syncing_id: nil)
         |> load_sources()}
    end
  end

  def handle_info(:do_sync_all, socket) do
    sources = socket.assigns.sources
    results = Enum.map(sources, &SkillSources.sync_from_source/1)
    total = results |> Enum.filter(&match?({:ok, _}, &1)) |> Enum.map(fn {:ok, r} -> r.synced end) |> Enum.sum()
    errors = Enum.count(results, &match?({:error, _}, &1))

    msg =
      if errors > 0,
        do: "Synced #{total} skill(s) from #{length(sources)} source(s), #{errors} failed",
        else: "Synced #{total} skill(s) from #{length(sources)} source(s)"

    flash = if errors > 0, do: :error, else: :info

    {:noreply,
     socket
     |> put_flash(flash, msg)
     |> assign(syncing_id: nil)
     |> load_sources()}
  end

  def handle_info({:fetch_remote_for_edit, source}, socket) do
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

  # ── Private ─────────────────────────────────────────────────────────────────

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

  defp parse_tags(input) when is_binary(input) do
    input
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(_), do: []

  defp tags_to_string(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_to_string(_), do: ""

  # ── Template ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= case @live_action do %>
        <% :index -> %>
          {render_index(assigns)}
        <% :new -> %>
          {render_new(assigns)}
        <% :edit -> %>
          {render_edit(assigns)}
        <% :show -> %>
          {render_index(assigns)}
      <% end %>
    </div>
    """
  end

  defp render_index(assigns) do
    ~H"""
    <div class="mb-6 flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold">Upstream Sources</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Configure GitHub repositories to sync skills from.
        </p>
      </div>
      <div class="flex items-center gap-1">
        <.dm_btn
          :if={@sources != []}
          size="sm"
          phx-click="export-sources"
          title="Export"
        >
          <.dm_mdi name="export" class="w-5 h-5" />
        </.dm_btn>
        <.dm_btn size="sm" phx-click="toggle-import" title="Import">
          <.dm_mdi name="import" class="w-5 h-5" />
        </.dm_btn>
        <.dm_btn
          :if={@sources != []}
          size="sm"
          phx-click="sync-all"
          disabled={@syncing_id == :all}
          title="Sync All"
        >
          <.dm_mdi name="sync" class={["w-5 h-5", @syncing_id == :all && "animate-spin"]} />
        </.dm_btn>
        <.link navigate={~p"/admin/skills/upstream/new"}>
          <.dm_btn variant="primary" size="sm" title="Add Source">
            <.dm_mdi name="plus" class="w-5 h-5" />
          </.dm_btn>
        </.link>
      </div>
    </div>

    <%!-- Import panel --%>
    <.dm_card :if={@show_import} variant="bordered" class="mb-6">
      <:title>Import Sources</:title>
      <.form for={%{}} phx-submit="import-sources" phx-change="validate-import" class="space-y-4">
        <div>
          <.live_file_input upload={@uploads.import_file} class="file-input file-input-bordered w-full" />
          <p class="mt-1 text-xs text-on-surface-variant">
            Upload a JSON file exported from another Backplane instance.
          </p>
        </div>
        <div :for={entry <- @uploads.import_file.entries} class="text-sm">
          <span class="font-medium">{entry.client_name}</span>
          <span class="text-on-surface-variant ml-2">{Float.round(entry.client_size / 1024, 1)} KB</span>
          <div :for={err <- upload_errors(@uploads.import_file, entry)} class="text-error text-xs">
            {inspect(err)}
          </div>
        </div>
        <div class="flex gap-2">
          <.dm_btn type="submit" variant="primary" size="sm"
            disabled={@uploads.import_file.entries == []}
          >
            Import
          </.dm_btn>
          <.dm_btn type="button" size="sm" phx-click="toggle-import">Cancel</.dm_btn>
        </div>
      </.form>
    </.dm_card>

    <div :if={@sources == []} class="text-on-surface-variant py-12 text-center">
      No upstream sources configured yet.
    </div>

    <div :if={@sources != []} class="space-y-4">
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
            <div class="flex items-center gap-1">
              <.dm_btn
                size="xs"
                variant="primary"
                phx-click="sync-source"
                phx-value-id={source.id}
                disabled={@syncing_id == source.id}
                title="Sync"
              >
                <.dm_mdi name="sync" class={["w-4 h-4", @syncing_id == source.id && "animate-spin"]} />
              </.dm_btn>
              <.link navigate={~p"/admin/skills/upstream/#{source.id}/edit"} class="no-underline">
                <.dm_btn size="xs" title="Edit">
                  <.dm_mdi name="pencil" class="w-4 h-4" />
                </.dm_btn>
              </.link>
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
          <div class="flex items-center gap-4">
            <div>
              <span class="font-medium">Last synced:</span>
              <span class="ml-1">{format_dt(source.last_synced_at)}</span>
            </div>
            <div :if={source.selected_skills != []}>
              <span class="font-medium">Selected:</span>
              <span class="ml-1">{length(source.selected_skills)} skill(s)</span>
            </div>
            <div :if={source.sync_tags != []}>
              <span class="font-medium">Tags:</span>
              <span class="ml-1">{tags_to_string(source.sync_tags)}</span>
            </div>
          </div>
          <div :if={source.last_sync_error} class="text-error text-xs">
            Error: {source.last_sync_error}
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp render_new(assigns) do
    ~H"""
    <div class="mb-6">
      <.link navigate={~p"/admin/skills/upstream"} class="text-sm text-on-surface-variant hover:text-on-surface no-underline">
        ← Back to Upstream Sources
      </.link>
    </div>

    <.dm_card variant="bordered">
      <:title>Add Upstream Source</:title>
      <.form for={@form} phx-submit="save-source" phx-change="validate-source" class="space-y-4">
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
            <label class="block text-sm font-medium mb-1">Type</label>
            <select
              name="skill_source[source_type]"
              class="select select-bordered w-full"
            >
              <option value="github" selected={Phoenix.HTML.Form.input_value(@form, :source_type) == "github"}>GitHub</option>
              <option value="git" selected={Phoenix.HTML.Form.input_value(@form, :source_type) == "git"}>Git</option>
            </select>
            <p class="mt-1 text-xs text-on-surface-variant">
              GitHub allows org/repo shorthand. Git requires full URL.
            </p>
          </div>
          <div class="sm:col-span-2">
            <.dm_input
              field={@form[:url]}
              label="Repository URL"
              placeholder={if Phoenix.HTML.Form.input_value(@form, :source_type) == "git", do: "https://git.example.com/org/skills-repo", else: "owner/repo or https://github.com/org/skills-repo"}
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

        <%!-- Sync Tags --%>
        <div>
          <label class="block text-sm font-medium mb-1">Sync Tags</label>
          <input
            type="text"
            value={@tag_input}
            phx-blur="update-tags"
            phx-keyup="update-tags"
            placeholder="tag1, tag2, tag3"
            class="input input-bordered w-full"
          />
          <p class="mt-1 text-xs text-on-surface-variant">
            Comma-separated. These tags will be applied to all synced skills from this source.
          </p>
        </div>

        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary" size="sm">Create</.dm_btn>
          <.link navigate={~p"/admin/skills/upstream"} class="no-underline">
            <.dm_btn type="button" size="sm">Cancel</.dm_btn>
          </.link>
        </div>
      </.form>
    </.dm_card>
    """
  end

  defp render_edit(assigns) do
    ~H"""
    <div class="mb-6">
      <.link navigate={~p"/admin/skills/upstream"} class="text-sm text-on-surface-variant hover:text-on-surface no-underline">
        ← Back to Upstream Sources
      </.link>
    </div>

    <%!-- Edit form --%>
    <.dm_card variant="bordered" class="mb-6">
      <:title>Edit Source</:title>
      <.form for={@form} phx-submit="update-source" phx-change="validate-source" class="space-y-4">
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
            <label class="block text-sm font-medium mb-1">Type</label>
            <select
              name="skill_source[source_type]"
              class="select select-bordered w-full"
            >
              <option value="github" selected={Phoenix.HTML.Form.input_value(@form, :source_type) == "github"}>GitHub</option>
              <option value="git" selected={Phoenix.HTML.Form.input_value(@form, :source_type) == "git"}>Git</option>
            </select>
            <p class="mt-1 text-xs text-on-surface-variant">
              GitHub allows org/repo shorthand. Git requires full URL.
            </p>
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

        <%!-- Sync Tags --%>
        <div>
          <label class="block text-sm font-medium mb-1">Sync Tags</label>
          <input
            type="text"
            value={@tag_input}
            phx-blur="update-tags"
            phx-keyup="update-tags"
            placeholder="tag1, tag2, tag3"
            class="input input-bordered w-full"
          />
          <p class="mt-1 text-xs text-on-surface-variant">
            Comma-separated. These tags will be applied to all synced skills from this source.
          </p>
        </div>

        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
          <.link navigate={~p"/admin/skills/upstream"} class="no-underline">
            <.dm_btn type="button" size="sm">Cancel</.dm_btn>
          </.link>
        </div>
      </.form>
    </.dm_card>

    <%!-- Skill Selector --%>
    <.dm_card variant="bordered" class="mb-6">
      <:title>
        <div class="flex items-center justify-between w-full">
          <div class="flex items-center gap-2">
            <span>Skills to Sync</span>
            <.dm_badge :if={@remote_skills != []} variant="neutral" size="sm">
              {MapSet.size(@selected_skills)}/{length(@remote_skills)} selected
            </.dm_badge>
          </div>
          <div class="flex items-center gap-2">
            <.dm_btn
              :if={@remote_skills != []}
              size="xs"
              phx-click="select-all-skills"
            >
              Select All
            </.dm_btn>
            <.dm_btn
              :if={MapSet.size(@selected_skills) > 0}
              size="xs"
              phx-click="clear-skills"
            >
              Clear
            </.dm_btn>
            <.dm_btn
              size="xs"
              variant="ghost"
              phx-click="refresh-remote"
              disabled={@remote_loading}
            >
              {if @remote_loading, do: "Loading…", else: "Refresh"}
            </.dm_btn>
          </div>
        </div>
      </:title>

      <div :if={@remote_loading} class="text-center py-6 text-on-surface-variant">
        <div class="text-sm">Fetching skills from upstream source…</div>
      </div>

      <div :if={@remote_error} class="py-4">
        <div class="text-sm text-error">
          Failed to fetch remote skills: {@remote_error}
        </div>
      </div>

      <div :if={@remote_skills == [] and not @remote_loading and not is_binary(@remote_error)} class="text-center py-6 text-on-surface-variant text-sm">
        No remote skills found. Click Refresh to fetch from the upstream source.
      </div>

      <div :if={@remote_skills != [] and not @remote_loading} class="divide-y divide-outline-variant/40">
        <div
          :for={skill <- @remote_skills}
          class="flex items-center gap-3 py-2 px-1 hover:bg-surface-container-high/50 rounded"
        >
          <input
            type="checkbox"
            checked={MapSet.member?(@selected_skills, skill[:slug])}
            phx-click="toggle-skill"
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

    <%!-- Danger zone --%>
    <.dm_card variant="bordered" class="border-error/30">
      <:title>
        <span class="text-error">Danger Zone</span>
      </:title>
      <div class="flex items-center justify-between">
        <div>
          <div class="text-sm font-medium">Delete this source</div>
          <div class="text-xs text-on-surface-variant">
            This will remove the upstream source configuration. Previously synced skills will not be deleted.
          </div>
        </div>
        <.dm_btn
          size="sm"
          variant="error"
          data-confirm={"Delete source #{@editing_source.name}? This cannot be undone."}
          phx-click="delete-source"
          phx-value-id={@editing_source.id}
        >
          Delete Source
        </.dm_btn>
      </div>
    </.dm_card>
    """
  end
end
