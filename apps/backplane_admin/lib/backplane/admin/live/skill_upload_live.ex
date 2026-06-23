defmodule Backplane.Admin.SkillUploadLive do
  @moduledoc """
  Upload archive-backed skills (.zip, .tar.gz, .tgz) and browse all
  skills ingested from archives, API, or host-agent uploads.
  """

  use Backplane.Admin, :live_view

  alias Backplane.Skills

  @accepted_types ~w(.tar.gz .tgz .zip)
  @max_file_size 50_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/skills/upload",
       loading: true,
       skills: [],
       uploading: false,
       upload_error: nil,
       detail_skill: nil
     )
     |> allow_upload(:archive,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_file_size,
       auto_upload: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(detail_skill: nil)
         |> load_skills()}

      :show ->
        skill_id = params["id"]

        case Skills.get(skill_id) do
          {:ok, skill} ->
            {:noreply,
             socket
             |> assign(detail_skill: skill, loading: false)
             |> load_skills()}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Skill not found")
             |> push_patch(to: ~p"/skills/upload")}
        end
    end
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    entries = socket.assigns.uploads.archive.entries

    if entries == [] do
      {:noreply, put_flash(socket, :error, "Please select a file to upload")}
    else
      entry = hd(entries)
      filename = entry.client_name

      if valid_extension?(filename) do
        socket = assign(socket, uploading: true, upload_error: nil)

        uploaded_files =
          consume_uploaded_entries(socket, :archive, fn %{path: path}, entry ->
            # Copy to a temp file since the upload path is transient
            dest = temp_path(entry.client_name)
            File.cp!(path, dest)
            {:ok, {dest, entry.client_name}}
          end)

        case uploaded_files do
          [{path, original_name}] ->
            result = ingest_file(path, original_name)
            File.rm(path)

            case result do
              {:ok, skills} when is_list(skills) ->
                names = Enum.map_join(skills, ", ", & &1.name)
                count = length(skills)

                {:noreply,
                 socket
                 |> assign(uploading: false)
                 |> put_flash(:info, "Uploaded #{count} skill(s): #{names}")
                 |> load_skills()}

              {:ok, %{name: name}} ->
                {:noreply,
                 socket
                 |> assign(uploading: false)
                 |> put_flash(:info, "Uploaded skill '#{name}' successfully")
                 |> load_skills()}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> assign(uploading: false)
                 |> put_flash(:error, "Upload failed: #{format_error(reason)}")}
            end

          _ ->
            {:noreply,
             socket
             |> assign(uploading: false)
             |> put_flash(:error, "No file was uploaded")}
        end
      else
        {:noreply,
         put_flash(socket, :error, "Unsupported file type. Please upload .tar.gz, .tgz, or .zip")}
      end
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :archive, ref)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Skills.delete(id) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted '#{deleted.name}'")
         |> load_skills()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill")}
    end
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/skills/upload")}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp load_skills(socket) do
    skills =
      Skills.list_all(source_kind: "archive")
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    assign(socket, skills: skills, loading: false)
  end

  defp valid_extension?(filename) do
    downcased = String.downcase(filename)

    Enum.any?(@accepted_types, fn ext ->
      String.ends_with?(downcased, ext)
    end)
  end

  defp ingest_file(path, filename) do
    downcased = String.downcase(filename)

    if String.ends_with?(downcased, ".zip") do
      tar_gz_path = temp_path("converted.tar.gz")

      try do
        with {:ok, entries} <- :zip.unzip(String.to_charlist(path), [:memory]),
             :ok <- create_tar_gz(entries, tar_gz_path) do
          ingest_smart(tar_gz_path, filename)
        end
      after
        File.rm(tar_gz_path)
      end
    else
      ingest_smart(path, filename)
    end
  end

  # ── Smart archive detection ──────────────────────────────────────────────

  defp ingest_smart(tar_gz_path, filename) do
    with {:ok, table_entries} <- tar_table(tar_gz_path) do
      skill_mds = find_skill_mds(table_entries)

      case classify_archive(skill_mds) do
        :empty ->
          {:error, :missing_skill_md}

        :root_skill ->
          ingest_root_skill(tar_gz_path, filename)

        :single_skill ->
          Skills.ingest_archive(tar_gz_path, [])

        {:multi_skill, roots} ->
          ingest_multi_skills(tar_gz_path, roots)
      end
    end
  end

  defp tar_table(path) do
    path
    |> String.to_charlist()
    |> :erl_tar.table([:compressed, :verbose])
  end

  defp find_skill_mds(table_entries) do
    Enum.reduce(table_entries, [], fn entry, acc ->
      name = normalize_entry_name(entry)

      if name && Path.basename(name) == "SKILL.md" do
        [name | acc]
      else
        acc
      end
    end)
  end

  defp normalize_entry_name({name, _type, _size, _mtime, _mode, _uid, _gid}) do
    IO.chardata_to_string(name)
  end

  defp normalize_entry_name({name, _size, _type}) do
    IO.chardata_to_string(name)
  end

  defp normalize_entry_name(_), do: nil

  defp classify_archive([]), do: :empty

  defp classify_archive([skill_md]) do
    dir = Path.dirname(skill_md)

    if dir in [".", ""] do
      :root_skill
    else
      :single_skill
    end
  end

  defp classify_archive(skill_mds) when is_list(skill_mds) do
    roots = Enum.map(skill_mds, &Path.dirname/1)
    {:multi_skill, roots}
  end

  # Case 1: SKILL.md at root — wrap all files in a directory named from the filename
  defp ingest_root_skill(tar_gz_path, filename) do
    wrapper = archive_filename_root(filename)

    with {:ok, mem_entries} <- extract_all_to_memory(tar_gz_path) do
      wrapped =
        Enum.map(mem_entries, fn {name, content} ->
          new_name = String.to_charlist(wrapper <> "/" <> IO.chardata_to_string(name))
          {new_name, content}
        end)

      wrapped_path = temp_path("wrapped-#{wrapper}.tar.gz")

      try do
        with :ok <- create_tar_gz(wrapped, wrapped_path) do
          Skills.ingest_archive(wrapped_path, [])
        end
      after
        File.rm(wrapped_path)
      end
    end
  end

  # Case 2: Multiple SKILL.md — split into per-skill archives and ingest each
  defp ingest_multi_skills(tar_gz_path, skill_roots) do
    with {:ok, mem_entries} <- extract_all_to_memory(tar_gz_path) do
      results =
        Enum.map(skill_roots, fn root ->
          # Collect entries belonging to this skill root
          entries_for_skill =
            Enum.filter(mem_entries, fn {name, _content} ->
              n = IO.chardata_to_string(name)
              n == root or String.starts_with?(n, root <> "/")
            end)

          if entries_for_skill == [] do
            {:error, {:empty_skill_root, root}}
          else
            slug = root |> Path.basename() |> slugify()
            sub_path = temp_path("multi-#{slug}.tar.gz")

            try do
              with :ok <- create_tar_gz(entries_for_skill, sub_path) do
                Skills.ingest_archive(sub_path, [])
              end
            after
              File.rm(sub_path)
            end
          end
        end)

      successes = for {:ok, skill} <- results, do: skill
      errors = for {:error, reason} <- results, do: reason

      case {successes, errors} do
        {[], [first_err | _]} ->
          {:error, first_err}

        {skills, []} ->
          {:ok, skills}

        {skills, errs} ->
          # Partial success — report skills but warn about errors
          names = Enum.map_join(errs, ", ", &inspect/1)

          require Logger
          Logger.warning("Partial skill upload: #{length(skills)} ok, errors: #{names}")

          {:ok, skills}
      end
    end
  end

  # ── Archive helpers ──────────────────────────────────────────────────────

  defp extract_all_to_memory(tar_gz_path) do
    tar_gz_path
    |> String.to_charlist()
    |> :erl_tar.extract([:memory, :compressed])
  end

  defp create_tar_gz(entries, dest_path) do
    case :erl_tar.create(String.to_charlist(dest_path), entries, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar_create_failed, reason}}
    end
  end

  defp archive_filename_root(filename) do
    base = Path.basename(to_string(filename))

    case Regex.run(~r/\A(.+)\.tar\.gz\z/i, base) do
      [_match, root] -> slugify(root)
      nil -> slugify(Path.rootname(base))
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slugify(_), do: "skill"

  defp temp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "backplane-skill-upload-#{System.unique_integer([:positive])}-#{suffix}"
    )
  end

  defp format_error({:slug_conflict, slug}),
    do: "Slug '#{slug}' conflicts with a non-archive skill"

  defp format_error(:missing_skill_md), do: "Archive must contain a SKILL.md file"
  defp format_error({:empty_skill_root, root}), do: "No files found for skill root '#{root}'"
  defp format_error(:invalid_archive_path), do: "Invalid archive file"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_dt(nil), do: ""
  defp format_dt(dt) do
    assigns = %{dt: dt}
    ~H"""
    <.local_time datetime={@dt} />
    """
  end

  defp format_size(nil), do: "-"
  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_size(_), do: "-"

  # ── Template ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Upload Skills</h1>
          <p class="text-sm text-on-surface-variant mt-1">
            Upload skill packages (.tar.gz, .tgz, .zip) or browse skills uploaded via API / agent.
          </p>
        </div>
      </div>

      <%!-- Upload form --%>
      <.dm_card variant="bordered" class="mb-6">
        <:title>Upload Skill Package</:title>
        <form
          id="upload-form"
          phx-submit="upload"
          phx-change="validate"
        >
          <div
            class="relative border-2 border-dashed border-outline-variant rounded-lg p-8 text-center transition-colors hover:border-primary hover:bg-primary/5"
            phx-drop-target={@uploads.archive.ref}
          >
            <.dm_mdi name="cloud-upload" class="w-12 h-12 mx-auto text-on-surface-variant mb-3" />
            <p class="text-on-surface font-medium mb-1">
              Drag & drop a skill package here
            </p>
            <p class="text-sm text-on-surface-variant mb-4">
              or click to browse — accepts .tar.gz, .tgz, .zip (max 50 MB)
            </p>
            <label class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-on-primary cursor-pointer hover:bg-primary/90 transition-colors text-sm font-medium">
              <.dm_mdi name="folder-open" class="w-4 h-4" />
              Choose File
              <.live_file_input upload={@uploads.archive} class="sr-only" />
            </label>
          </div>

          <%!-- Selected file preview --%>
          <div :for={entry <- @uploads.archive.entries} class="mt-4 flex items-center gap-3 p-3 rounded-lg bg-surface-container">
            <.dm_mdi name="file-document" class="w-6 h-6 text-primary shrink-0" />
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-on-surface truncate">{entry.client_name}</p>
              <p class="text-xs text-on-surface-variant">{format_size(entry.client_size)}</p>
            </div>
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              class="p-1 rounded hover:bg-error/10 text-on-surface-variant hover:text-error transition-colors"
              aria-label="Remove file"
            >
              <.dm_mdi name="close" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Upload errors --%>
          <div :for={err <- upload_errors(@uploads.archive)} class="mt-2 text-sm text-error">
            {upload_error_to_string(err)}
          </div>

          <div class="mt-4 flex gap-2">
            <.dm_btn
              type="submit"
              variant="primary"
              size="sm"
              disabled={@uploads.archive.entries == [] or @uploading}
            >
              <.dm_mdi :if={@uploading} name="loading" class="w-4 h-4 animate-spin mr-1" />
              {if @uploading, do: "Uploading…", else: "Upload"}
            </.dm_btn>
          </div>
        </form>
      </.dm_card>

      <%!-- Detail panel --%>
      <.dm_card :if={@detail_skill} variant="bordered" class="mb-6">
        <:title>
          <div class="flex items-center justify-between">
            <span>Skill Detail: {@detail_skill.name}</span>
            <.dm_btn type="button" size="xs" shape="circle" class="group relative" phx-click="close-detail">
              <.dm_mdi name="close" class="w-4 h-4" />
              <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
                Close
              </span>
            </.dm_btn>
          </div>
        </:title>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 text-sm">
          <div>
            <span class="text-on-surface-variant">Slug:</span>
            <code class="ml-1">{@detail_skill.slug}</code>
          </div>
          <div>
            <span class="text-on-surface-variant">Category:</span>
            <span class="ml-1">{@detail_skill.category || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Version:</span>
            <span class="ml-1">{@detail_skill.version || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Author:</span>
            <span class="ml-1">{@detail_skill.author || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">License:</span>
            <span class="ml-1">{@detail_skill.license || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Homepage:</span>
            <span class="ml-1">{@detail_skill.homepage || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Size:</span>
            <span class="ml-1">{format_size(@detail_skill.size_bytes)}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Files:</span>
            <span class="ml-1">{@detail_skill.file_count || "-"}</span>
          </div>
          <div>
            <span class="text-on-surface-variant">Source:</span>
            <span class="ml-1">{@detail_skill.source_kind || "-"}</span>
          </div>
        </div>
        <div :if={@detail_skill.description && @detail_skill.description != ""} class="mt-3">
          <span class="text-on-surface-variant text-sm">Description:</span>
          <p class="mt-1 text-sm">{@detail_skill.description}</p>
        </div>
        <div :if={@detail_skill.tags != []} class="mt-3 flex flex-wrap gap-1">
          <.dm_badge :for={tag <- @detail_skill.tags} variant="ghost" size="sm">{tag}</.dm_badge>
        </div>
      </.dm_card>

      <%!-- Skills list --%>
      <div :if={@skills == [] and not @loading} class="text-on-surface-variant py-12 text-center">
        No uploaded skills yet. Upload a package above or push via the API.
      </div>

      <.dm_table :if={@skills != []} id="upload-skills-table" data={@skills} hover zebra>
        <:col :let={skill} label="Name">
          <.link patch={~p"/skills/upload/#{skill.id}"} class="font-medium text-primary hover:underline">
            {skill.name}
          </.link>
        </:col>
        <:col :let={skill} label="Description">
          <div :if={skill.description && skill.description != ""} class="group relative max-w-[240px]">
            <span class="block truncate text-sm text-on-surface-variant cursor-default">
              {skill.description}
            </span>
            <div class="invisible group-hover:visible absolute left-0 top-full z-50 mt-1 max-w-sm rounded-lg border border-outline-variant bg-surface-container-high p-3 text-sm text-on-surface shadow-lg">
              {skill.description}
            </div>
          </div>
          <span :if={!skill.description || skill.description == ""} class="text-xs text-on-surface-variant">-</span>
        </:col>
        <:col :let={skill} label="Slug">
          <code class="text-xs">{skill.slug}</code>
        </:col>
        <:col :let={skill} label="Size">
          <span class="text-sm">{format_size(skill.size_bytes)}</span>
        </:col>
        <:col :let={skill} label="Files">
          <span class="text-sm">{skill.file_count || "-"}</span>
        </:col>
        <:col :let={skill} label="Tags">
          <div class="flex flex-wrap gap-1">
            <.dm_badge :for={tag <- skill.tags} variant="ghost" size="sm">{tag}</.dm_badge>
            <span :if={skill.tags == []} class="text-xs text-on-surface-variant">-</span>
          </div>
        </:col>
        <:col :let={skill} label="Updated">
          <span class="text-xs text-on-surface-variant">{format_dt(skill.updated_at)}</span>
        </:col>
        <:col :let={skill} label="Actions">
          <div class="flex gap-1">
            <.link patch={~p"/skills/upload/#{skill.id}"} class="no-underline">
              <.dm_btn type="button" size="xs" shape="circle" class="group relative">
                <.dm_mdi name="eye" class="w-4 h-4" />
                <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
                  View
                </span>
              </.dm_btn>
            </.link>
            <.dm_btn
              type="button"
              size="xs"
              shape="circle"
              variant="error"
              class="group relative"
              confirm={"Delete skill '#{skill.name}'?"}
              confirm_title="Confirm Delete"
              phx-click="delete"
              phx-value-id={skill.id}
            >
              <.dm_mdi name="delete" class="w-4 h-4" />
              <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
                Delete
              </span>
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: "File is too large (max 50 MB)"
  defp upload_error_to_string(:too_many_files), do: "Only one file at a time"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(err), do: inspect(err)
end
