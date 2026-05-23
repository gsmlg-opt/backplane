defmodule BackplaneWeb.SkillLive do
  use BackplaneWeb, :live_view

  alias Backplane.Settings
  alias Backplane.Skills

  @max_results 100
  @default_upload_max_bytes 20_000_000

  @impl true
  def mount(_params, _session, socket) do
    upload_max_bytes = upload_max_bytes()

    socket =
      socket
      |> assign(
        current_path: "/admin/skills",
        loading: true,
        q: "",
        skills: [],
        upload_error: nil,
        upload_max_bytes: upload_max_bytes
      )
      |> allow_upload(:archive,
        accept: ~w(.gz application/gzip application/x-tar+gzip),
        max_entries: 1,
        max_file_size: upload_max_bytes
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    q = normalize_query(params["q"])

    {:noreply,
     assign(socket,
       current_path: current_path(uri),
       loading: false,
       q: q,
       skills: Skills.search(q, archive_only: true, limit: @max_results)
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: skills_path(normalize_query(q)))}
  end

  def handle_event("validate-upload", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  def handle_event("upload", _params, socket) do
    case consume_archive_upload(socket) do
      [] ->
        {:noreply, assign(socket, upload_error: "Choose a .tar.gz archive to upload.")}

      [{:ok, skill}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Uploaded #{skill.name}")
         |> assign(upload_error: nil)
         |> push_patch(to: skills_path(socket.assigns.q))}

      [{:error, message}] ->
        {:noreply, assign(socket, upload_error: "Upload failed: #{message}")}
    end
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    with {:ok, skill} <- Skills.get_by_slug(slug),
         {:ok, deleted} <- Skills.delete(skill) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted #{deleted.name}")
       |> push_patch(to: skills_path(socket.assigns.q))}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
        <div>
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold">Skills Hub</h1>
            <.dm_badge variant="neutral" size="sm">{length(@skills)} shown</.dm_badge>
          </div>
          <p class="mt-1 text-sm text-on-surface-variant">
            Upload and manage archive-backed skills available through the managed Skills service.
          </p>
        </div>

        <form
          id="skill-search-form"
          phx-submit="search"
          class="flex w-full flex-col gap-2 sm:w-auto sm:min-w-96 sm:flex-row sm:items-end"
        >
          <.dm_input
            name="q"
            label="Search"
            value={@q}
            placeholder="Name, slug, tag, or content"
            size="sm"
            field_class="sm:min-w-72"
          />
          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary" size="sm">Search</.dm_btn>
            <.link :if={@q != ""} patch={~p"/admin/skills"} class="no-underline">
              <.dm_btn type="button" size="sm">Clear</.dm_btn>
            </.link>
          </div>
        </form>
      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>
          <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
            <span>Upload Skill Archive</span>
            <span class="text-xs font-normal text-on-surface-variant">
              max {format_size(@upload_max_bytes)}
            </span>
          </div>
        </:title>

        <form
          id="skill-upload-form"
          phx-change="validate-upload"
          phx-submit="upload"
          enctype="multipart/form-data"
          class="space-y-3"
        >
          <div class="flex flex-col gap-3 md:flex-row md:items-end">
            <div class="min-w-0 flex-1">
              <.live_file_input upload={@uploads.archive} class="block w-full text-sm" />
              <p class="mt-1 text-xs text-on-surface-variant">
                Accepts one .tar.gz skill archive.
              </p>
            </div>
            <.dm_btn type="submit" variant="primary" size="sm">Upload</.dm_btn>
          </div>

          <div
            :for={entry <- @uploads.archive.entries}
            class="rounded-md border border-outline-variant px-3 py-2 text-sm"
          >
            <div class="flex items-center justify-between gap-3">
              <span class="truncate font-mono text-xs">{entry.client_name}</span>
              <span class="text-xs text-on-surface-variant">{entry.progress}%</span>
            </div>
            <p
              :for={error <- upload_errors(@uploads.archive, entry)}
              class="mt-1 text-xs text-error"
            >
              {upload_error(error)}
            </p>
          </div>

          <p :if={@upload_error} class="text-sm text-error">{@upload_error}</p>
          <p :for={error <- upload_errors(@uploads.archive)} class="text-sm text-error">
            {upload_error(error)}
          </p>
        </form>
      </.dm_card>

      <div :if={@skills == []} class="text-sm text-on-surface-variant">
        {empty_state_text(@q)}
      </div>

      <.dm_table :if={@skills != []} id="skills-table" data={@skills} hover zebra>
        <:col :let={skill} label="Name">
          <div class="min-w-0">
            <div class="font-medium text-on-surface">{skill.name}</div>
            <div class="truncate text-xs text-on-surface-variant">{skill.description}</div>
          </div>
        </:col>
        <:col :let={skill} label="Slug">
          <code class="text-xs">{skill.slug}</code>
        </:col>
        <:col :let={skill} label="Tags">
          <div class="flex flex-wrap gap-1">
            <.dm_badge :for={tag <- skill.tags} variant="ghost" size="sm">{tag}</.dm_badge>
            <span :if={skill.tags == []} class="text-xs text-on-surface-variant">-</span>
          </div>
        </:col>
        <:col :let={skill} label="Hash">
          <span class="font-mono text-xs break-all">{skill.content_hash}</span>
        </:col>
        <:col :let={skill} label="Size">
          <span class="text-sm">{format_size(skill.size_bytes)}</span>
        </:col>
        <:col :let={skill} label="Actions">
          <div class="flex flex-wrap gap-2">
            <a href={archive_path(skill.slug)} class="no-underline">
              <.dm_btn type="button" size="xs">Download</.dm_btn>
            </a>
            <.dm_btn
              id={"#{skill.slug}-delete"}
              type="button"
              variant="error"
              size="xs"
              data-confirm={"Delete skill #{skill.name}?"}
              phx-click="delete"
              phx-value-slug={skill.slug}
            >
              Delete
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp consume_archive_upload(socket) do
    consume_uploaded_entries(socket, :archive, fn %{path: path}, entry ->
      result =
        if tar_gz?(entry.client_name) do
          case Skills.ingest_archive(%{path: path, filename: entry.client_name}, []) do
            {:ok, skill} -> {:ok, skill}
            {:error, reason} -> {:error, format_error(reason)}
          end
        else
          {:error, "only .tar.gz archives can be uploaded"}
        end

      {:ok, result}
    end)
  end

  defp upload_max_bytes do
    case Settings.get("skills.archive.max_bytes") do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @default_upload_max_bytes
    end
  end

  defp current_path(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) -> path
      _ -> "/admin/skills"
    end
  end

  defp skills_path(""), do: ~p"/admin/skills"
  defp skills_path(q), do: ~p"/admin/skills?#{[q: q]}"

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.replace(<<0>>, "")
    |> String.slice(0, 500)
  end

  defp normalize_query(_), do: ""

  defp tar_gz?(filename) when is_binary(filename) do
    filename
    |> String.downcase()
    |> String.ends_with?(".tar.gz")
  end

  defp tar_gz?(_), do: false

  defp archive_path(slug), do: "/api/skills/#{URI.encode(slug)}/archive"

  defp empty_state_text(""), do: "No archive-backed skills uploaded."
  defp empty_state_text(_q), do: "No skills match the current search."

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KiB"
  end

  defp format_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp format_size(_), do: "-"

  defp upload_error(:too_large), do: "Archive exceeds the upload size limit."
  defp upload_error(:too_many_files), do: "Only one archive can be uploaded at a time."
  defp upload_error(:not_accepted), do: "Only .tar.gz archives can be uploaded."
  defp upload_error(error), do: format_error(error)

  defp format_error(error) when is_atom(error) do
    error
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_error(error), do: inspect(error)
end
