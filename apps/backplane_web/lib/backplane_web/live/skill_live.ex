defmodule BackplaneWeb.SkillLive do
  use BackplaneWeb, :live_view

  alias Backplane.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/admin/skills",
       loading: true,
       query: "",
       skills: [],
       upload_error: nil
     )
     |> allow_upload(:archive,
       accept: ~w(.gz),
       max_entries: 1,
       max_file_size: Backplane.Settings.get("skills.archive.max_bytes") || 20_000_000,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Map.get(params, "q", "")

    {:noreply,
     socket
     |> assign(query: query, upload_error: nil)
     |> load_skills()}
  end

  @impl true
  def handle_event("search", params, socket) do
    query = params |> Map.get("q", "") |> String.trim()

    path =
      if query == "" do
        ~p"/admin/skills"
      else
        ~p"/admin/skills?#{[q: query]}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("upload", _params, socket) do
    errors = socket.assigns.uploads.archive.errors

    cond do
      errors != [] ->
        {:noreply, assign(socket, upload_error: upload_error_message(List.first(errors)))}

      uploaded_entries(socket, :archive) |> elem(0) == [] ->
        {:noreply, assign(socket, upload_error: "Choose a .tar.gz archive")}

      true ->
        results =
          consume_uploaded_entries(socket, :archive, fn %{path: path}, entry ->
            path
            |> File.read!()
            |> Skills.ingest_archive(filename: entry.client_name)
            |> case do
              {:ok, skill} -> {:ok, {:ok, skill}}
              {:error, reason} -> {:ok, {:error, reason}}
            end
          end)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:info, "Skill uploaded")
             |> assign(upload_error: nil)
             |> load_skills()}

          {:error, reason} ->
            {:noreply, assign(socket, upload_error: upload_error_message(reason))}
        end
    end
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    case Skills.delete(slug) do
      {:ok, _skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill deleted")
         |> load_skills()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill")}
    end
  end

  defp load_skills(socket) do
    query = socket.assigns.query
    skills = Skills.list(q: query, limit: 100)

    assign(socket, loading: false, skills: skills)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="text-sm font-medium text-tertiary">Skill Hub</p>
          <h1 class="mt-1 text-2xl font-semibold tracking-normal text-on-surface">Skills</h1>
          <p class="mt-2 max-w-2xl text-sm text-on-surface-variant">
            Archive library for portable agent skills.
          </p>
        </div>

        <form id="skill-search-form" phx-submit="search" class="flex w-full gap-2 lg:w-[28rem]">
          <.dm_input
            name="q"
            value={@query}
            placeholder="Search skills"
            aria-label="Search skills"
            class="min-w-0 flex-1"
          />
          <.dm_btn type="submit" variant="primary">Search</.dm_btn>
        </form>
      </div>

      <.dm_card variant="bordered">
        <:title>
          <div class="flex items-center justify-between gap-4">
            <span>Upload</span>
            <.dm_badge variant="ghost">.tar.gz</.dm_badge>
          </div>
        </:title>

        <form id="skill-upload-form" phx-submit="upload" class="space-y-4">
          <div class="rounded-md border border-dashed border-outline-variant bg-surface-container p-4">
            <.live_file_input upload={@uploads.archive} class="block w-full text-sm" />

            <div :for={entry <- @uploads.archive.entries} class="mt-3">
              <div class="flex items-center justify-between gap-3 text-sm">
                <span class="font-medium">{entry.client_name}</span>
                <span class="text-on-surface-variant">{entry.progress}%</span>
              </div>
              <div class="mt-2 h-2 overflow-hidden rounded bg-surface-container-high">
                <div class="h-full bg-primary" style={"width: #{entry.progress}%"}></div>
              </div>
            </div>
          </div>

          <p :if={@upload_error} class="text-sm text-error">{@upload_error}</p>

          <div class="flex justify-end">
            <.dm_btn type="submit" variant="primary">Upload</.dm_btn>
          </div>
        </form>
      </.dm_card>

      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold text-on-surface">Library</h2>
          <span class="text-sm text-on-surface-variant">{length(@skills)} skills</span>
        </div>

        <div :if={@skills == []} class="rounded-md border border-outline-variant bg-surface p-8 text-center">
          <p class="text-sm text-on-surface-variant">No skills found.</p>
        </div>

        <.dm_card :for={skill <- @skills} variant="bordered">
          <:title>
            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-semibold">{skill.name}</span>
                  <.dm_badge variant="neutral">{skill.slug}</.dm_badge>
                  <.dm_badge :if={skill.version} variant="ghost">v{skill.version}</.dm_badge>
                </div>
                <p class="mt-1 text-sm text-on-surface-variant">{skill.description}</p>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <a
                  :if={skill.archive_ref}
                  href={"/api/skills/#{URI.encode(skill.slug)}/archive"}
                  class="no-underline"
                >
                  <.dm_btn size="sm" variant="outline" type="button">Download</.dm_btn>
                </a>
                <.dm_btn
                  size="sm"
                  variant="warning"
                  type="button"
                  phx-click="delete"
                  phx-value-slug={skill.slug}
                  data-confirm={"Delete #{skill.name}?"}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </:title>

          <div class="space-y-3">
            <div class="flex flex-wrap gap-2">
              <.dm_badge :for={tag <- skill.tags || []} variant="ghost">{tag}</.dm_badge>
            </div>

            <dl class="grid gap-3 text-sm md:grid-cols-3">
              <div>
                <dt class="text-xs uppercase text-on-surface-variant">Hash</dt>
                <dd class="mt-1 break-all font-mono text-xs">{skill.content_hash}</dd>
              </div>
              <div>
                <dt class="text-xs uppercase text-on-surface-variant">Size</dt>
                <dd class="mt-1 font-medium">{format_bytes(skill.size_bytes)}</dd>
              </div>
              <div>
                <dt class="text-xs uppercase text-on-surface-variant">Files</dt>
                <dd class="mt-1 font-medium">{skill.file_count || 0}</dd>
              </div>
            </dl>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp upload_error_message(:too_large), do: "Archive exceeds the configured size limit"
  defp upload_error_message(:too_many_files), do: "Archive has too many files"
  defp upload_error_message(:not_accepted), do: "Choose a .tar.gz archive"
  defp upload_error_message(:invalid_archive), do: "Invalid archive"
  defp upload_error_message(:missing_skill_md), do: "Invalid archive: SKILL.md is required"
  defp upload_error_message(:unsafe_path), do: "Invalid archive: unsafe paths are not allowed"

  defp upload_error_message(:unsupported_entry),
    do: "Invalid archive: unsupported entries are not allowed"

  defp upload_error_message(:malformed_meta), do: "Invalid archive: meta.json is malformed"
  defp upload_error_message(_reason), do: "Invalid archive"

  defp format_bytes(nil), do: "0 B"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
