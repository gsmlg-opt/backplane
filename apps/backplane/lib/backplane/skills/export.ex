defmodule Backplane.Skills.Export do
  @moduledoc """
  Collection import/export for archive-backed skills.

  A collection archive is a gzip-compressed tarball with this format:

    * `manifest.json`
    * `archives/<slug>.tar.gz`

  The manifest is bookkeeping only. Imports validate it as JSON, then ingest the
  archive entries themselves without rewriting individual skill archives.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Blob
  alias Backplane.Skills.Ingest
  alias Backplane.Skills.Skill

  @manifest_path "manifest.json"
  @archives_prefix "archives/"
  @archive_suffix ".tar.gz"
  @collection_format "backplane.skills.collection"
  @collection_version 1

  @type export_result :: %{path: String.t(), count: non_neg_integer()}
  @type import_result :: %{count: non_neg_integer(), skills: [Skill.t()]}

  @doc "Write archive-backed skills to a collection archive."
  @spec export(keyword() | map()) :: {:ok, export_result()} | {:error, term()}
  def export(opts \\ []) do
    opts = normalize_opts(opts)
    path = Keyword.get_lazy(opts, :path, &temp_collection_path/0)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         skills = archive_backed_skills(),
         {:ok, archives} <- archived_skill_entries(skills),
         {:ok, manifest_json} <- manifest_json(archives),
         :ok <- write_collection(path, manifest_json, archives) do
      {:ok, %{path: path, count: length(archives)}}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Import every skill archive from a collection archive."
  @spec import(String.t() | %{path: String.t()}, keyword() | map()) ::
          {:ok, import_result()} | {:error, term()}
  def import(path_or_upload, opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, path} <- collection_path(path_or_upload),
         {:ok, entries} <- validated_entries(path),
         {:ok, _manifest} <- read_manifest(path, entries) do
      import_archives(path, archive_entries(entries), opts)
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts) when is_list(opts), do: opts

  defp archive_backed_skills do
    Skill
    |> where([s], s.source_kind == "archive" and not is_nil(s.archive_ref))
    |> order_by([s], asc: s.slug)
    |> Repo.all()
  end

  defp archived_skill_entries(skills) do
    skills
    |> Enum.reduce_while({:ok, []}, fn %Skill{} = skill, {:ok, acc} ->
      with {:ok, entry_path} <- archive_entry_path(skill.slug),
           {:ok, stream} <- Blob.get(skill.archive_ref),
           archive <- Enum.into(stream, <<>>) do
        entry = %{path: entry_path, skill: skill, archive: archive}
        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp archive_entry_path(slug) when is_binary(slug) do
    if safe_slug?(slug) do
      {:ok, @archives_prefix <> slug <> @archive_suffix}
    else
      {:error, {:unsafe_slug, slug}}
    end
  end

  defp archive_entry_path(slug), do: {:error, {:unsafe_slug, slug}}

  defp safe_slug?(slug), do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, slug)

  defp manifest_json(archives) do
    manifest = %{
      "format" => @collection_format,
      "version" => @collection_version,
      "exported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "count" => length(archives),
      "skills" => Enum.map(archives, &manifest_skill/1)
    }

    {:ok, Jason.encode!(manifest)}
  end

  defp manifest_skill(%{path: archive_path, skill: %Skill{} = skill}) do
    %{
      "slug" => skill.slug,
      "name" => skill.name,
      "description" => skill.description,
      "tags" => skill.tags || [],
      "version" => skill.version,
      "license" => skill.license,
      "homepage" => skill.homepage,
      "author" => skill.author,
      "content_hash" => skill.content_hash,
      "archive_ref" => skill.archive_ref,
      "archive_path" => archive_path,
      "size_bytes" => skill.size_bytes,
      "file_count" => skill.file_count,
      "source_kind" => skill.source_kind
    }
  end

  defp write_collection(path, manifest_json, archives) do
    entries =
      [{String.to_charlist(@manifest_path), manifest_json}] ++
        Enum.map(archives, fn %{path: entry_path, archive: archive} ->
          {String.to_charlist(entry_path), archive}
        end)

    case :erl_tar.create(String.to_charlist(path), entries, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp collection_path(path) when is_binary(path), do: {:ok, path}
  defp collection_path(%{path: path}) when is_binary(path), do: {:ok, path}
  defp collection_path(_), do: {:error, :invalid_collection_path}

  defp validated_entries(path) do
    with {:ok, table_entries} <- table(path),
         {:ok, entries} <- normalize_entries(table_entries),
         :ok <- reject_duplicate_paths(entries),
         :ok <- require_manifest(entries) do
      {:ok, entries}
    end
  end

  defp table(path) do
    case :erl_tar.table(String.to_charlist(path), [:compressed, :verbose]) do
      {:ok, entries} -> {:ok, entries}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, normalized} <- normalize_entry(entry),
           :ok <- validate_entry(normalized) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries |> Enum.reverse() |> Enum.sort_by(& &1.name)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entry({name, type, size, _mtime, _mode, _uid, _gid}) do
    {:ok, %{name: IO.chardata_to_string(name), type: type, size: size}}
  end

  defp normalize_entry({name, size, type}) do
    {:ok, %{name: IO.chardata_to_string(name), type: type, size: size}}
  end

  defp normalize_entry(_), do: {:error, :malformed_tar_entry}

  defp validate_entry(%{name: name, type: type}) do
    with :ok <- validate_entry_name(name),
         :ok <- validate_entry_type(name, type),
         :ok <- validate_supported_path(name) do
      :ok
    end
  end

  defp validate_entry_name(name) do
    cond do
      name == "" ->
        {:error, {:unsafe_path, name}}

      Path.type(name) == :absolute ->
        {:error, {:unsafe_path, name}}

      windows_drive_path?(name) ->
        {:error, {:unsafe_path, name}}

      String.contains?(name, "\\") ->
        {:error, {:unsafe_path, name}}

      ".." in path_segments(name) ->
        {:error, {:unsafe_path, name}}

      percent_encoded_dot_path?(name) ->
        {:error, {:unsafe_path, name}}

      true ->
        :ok
    end
  end

  defp validate_entry_type(_name, :regular), do: :ok
  defp validate_entry_type(name, type), do: {:error, {:unsupported_entry_type, name, type}}

  defp validate_supported_path(@manifest_path), do: :ok

  defp validate_supported_path(@archives_prefix <> rest = name) do
    slug = String.replace_suffix(rest, @archive_suffix, "")

    cond do
      rest == "" -> {:error, {:unsupported_path, name}}
      String.contains?(rest, "/") -> {:error, {:unsupported_path, name}}
      not String.ends_with?(rest, @archive_suffix) -> {:error, {:unsupported_path, name}}
      not safe_slug?(slug) -> {:error, {:unsupported_path, name}}
      true -> :ok
    end
  end

  defp validate_supported_path(name), do: {:error, {:unsupported_path, name}}

  defp reject_duplicate_paths(entries) do
    entries
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {name, _count} -> {:error, {:duplicate_path, name}}
    end
  end

  defp require_manifest(entries) do
    if Enum.any?(entries, &(&1.name == @manifest_path)) do
      :ok
    else
      {:error, :missing_manifest}
    end
  end

  defp read_manifest(path, _entries) do
    with {:ok, contents} <- extract_memory(path, [@manifest_path]),
         {:ok, json} <- Map.fetch(contents, @manifest_path) do
      case Jason.decode(json) do
        {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
        {:ok, _value} -> {:error, :malformed_manifest}
        {:error, _reason} -> {:error, :malformed_manifest}
      end
    else
      :error -> {:error, :missing_manifest}
      {:error, _reason} = error -> error
    end
  end

  defp extract_memory(path, names) do
    files = Enum.map(names, &String.to_charlist/1)

    case :erl_tar.extract(String.to_charlist(path), [:compressed, :memory, {:files, files}]) do
      {:ok, entries} ->
        contents =
          Map.new(entries, fn {name, content} ->
            {IO.chardata_to_string(name), IO.iodata_to_binary(content)}
          end)

        {:ok, contents}

      {:error, _reason} = error ->
        error
    end
  end

  defp archive_entries(entries) do
    Enum.filter(entries, &String.starts_with?(&1.name, @archives_prefix))
  end

  defp import_archives(_collection_path, [], _opts), do: {:ok, %{count: 0, skills: []}}

  defp import_archives(collection_path, archive_entries, opts) do
    temp_dir = temp_import_dir()

    try do
      with :ok <- File.mkdir_p(temp_dir),
           :ok <- extract_archives(collection_path, archive_entries, temp_dir),
           {:ok, skills} <- ingest_archives(archive_entries, temp_dir, ingest_opts(opts)) do
        {:ok, %{count: length(skills), skills: skills}}
      end
    after
      File.rm_rf(temp_dir)
    end
  end

  defp extract_archives(collection_path, entries, temp_dir) do
    files = entries |> Enum.map(& &1.name) |> Enum.map(&String.to_charlist/1)

    case :erl_tar.extract(String.to_charlist(collection_path), [
           :compressed,
           {:cwd, String.to_charlist(temp_dir)},
           {:files, files}
         ]) do
      :ok -> :ok
      {:ok, _entries} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ingest_archives(entries, temp_dir, opts) do
    entries
    |> Enum.reduce_while({:ok, []}, fn %{name: name}, {:ok, acc} ->
      path = Path.join(temp_dir, name)

      case Ingest.ingest(path, opts) do
        {:ok, %Skill{} = skill} -> {:cont, {:ok, [skill | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, skills} -> {:ok, Enum.reverse(skills)}
      {:error, _reason} = error -> error
    end
  end

  defp ingest_opts(opts), do: Keyword.get(opts, :ingest, opts)

  defp windows_drive_path?(name),
    do: Enum.any?(path_segments(name), &Regex.match?(~r/^[A-Za-z]:/, &1))

  defp percent_encoded_dot_path?(name),
    do: Enum.any?(path_segments(name), &Regex.match?(~r/%2e/i, &1))

  defp path_segments(name), do: String.split(name, "/", trim: false)

  defp temp_collection_path do
    Path.join(System.tmp_dir!(), "backplane-skills-collection-#{unique_id()}.tar.gz")
  end

  defp temp_import_dir do
    Path.join(System.tmp_dir!(), "backplane-skills-import-#{unique_id()}")
  end

  defp unique_id, do: System.unique_integer([:positive])
end
