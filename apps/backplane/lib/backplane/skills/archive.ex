defmodule Backplane.Skills.Archive do
  @moduledoc """
  Reads and validates uploaded skill archives.
  """

  import Kernel, except: [inspect: 1, inspect: 2]

  alias Backplane.Skills.Loader

  @default_max_files 500

  @type result :: %{
          skill_md: binary(),
          skill_entry: map(),
          meta: map(),
          files: [String.t()],
          file_count: non_neg_integer(),
          size_bytes: non_neg_integer()
        }

  @spec inspect(String.t() | %{path: String.t()}, keyword()) :: {:ok, result()} | {:error, term()}
  def inspect(path_or_upload, opts \\ []) do
    with {:ok, path} <- archive_path(path_or_upload),
         {:ok, %{size: size_bytes}} <- File.stat(path),
         {:ok, table_entries} <- table(path),
         {:ok, file_entries} <- validate_table_entries(table_entries, opts),
         {:ok, root, skill_path} <- skill_root(file_entries),
         :ok <- validate_single_root(file_entries, root),
         {:ok, contents} <- extract_contents(path),
         {:ok, skill_md} <- fetch_content(contents, skill_path),
         {:ok, skill_entry} <- parse_skill(skill_md),
         {:ok, meta} <- read_meta(contents, Path.join(root, "meta.json")) do
      files =
        file_entries
        |> Enum.map(fn %{name: name} -> Path.relative_to(name, root) end)
        |> Enum.sort()

      {:ok,
       %{
         skill_md: skill_md,
         skill_entry: skill_entry,
         meta: meta,
         files: files,
         file_count: length(file_entries),
         size_bytes: size_bytes
       }}
    else
      {:error, _} = error -> error
      {:error, module, reason} -> {:error, {module, reason}}
    end
  end

  defp archive_path(path) when is_binary(path), do: {:ok, path}
  defp archive_path(%{path: path}) when is_binary(path), do: {:ok, path}
  defp archive_path(_), do: {:error, :invalid_archive_path}

  defp table(path) do
    path
    |> String.to_charlist()
    |> :erl_tar.table([:compressed, :verbose])
  end

  defp validate_table_entries(entries, opts) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    with {:ok, normalized} <- normalize_entries(entries) do
      file_entries = Enum.filter(normalized, &(&1.type == :regular))
      file_count = length(file_entries)

      if file_count > max_files do
        {:error, {:too_many_files, file_count, max_files}}
      else
        {:ok, file_entries}
      end
    end
  end

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, name, type} <- normalize_entry(entry),
           :ok <- validate_entry_name(name),
           :ok <- validate_entry_type(name, type) do
        {:cont, {:ok, [%{name: name, type: type} | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp normalize_entry({name, type, _size, _mtime, _mode, _uid, _gid}) do
    {:ok, IO.chardata_to_string(name), type}
  end

  defp normalize_entry({name, _size, type}) do
    {:ok, IO.chardata_to_string(name), type}
  end

  defp normalize_entry(_), do: {:error, :malformed_tar_entry}

  defp validate_entry_name(name) do
    cond do
      name == "" ->
        {:error, {:unsafe_path, name}}

      Path.type(name) == :absolute ->
        {:error, {:unsafe_path, name}}

      ".." in String.split(name, "/", trim: false) ->
        {:error, {:unsafe_path, name}}

      true ->
        :ok
    end
  end

  defp validate_entry_type(_name, :regular), do: :ok
  defp validate_entry_type(_name, :directory), do: :ok
  defp validate_entry_type(name, type), do: {:error, {:unsupported_entry_type, name, type}}

  defp skill_root(file_entries) do
    case Enum.filter(file_entries, &(Path.basename(&1.name) == "SKILL.md")) do
      [%{name: skill_path}] ->
        root = Path.dirname(skill_path)

        if root in [".", ""] do
          {:error, :missing_skill_root}
        else
          {:ok, root, skill_path}
        end

      [] ->
        {:error, :missing_skill_md}

      _multiple ->
        {:error, :ambiguous_skill_md}
    end
  end

  defp validate_single_root(file_entries, root) do
    if Enum.all?(file_entries, &under_root?(&1.name, root)) do
      :ok
    else
      {:error, :ambiguous_archive}
    end
  end

  defp under_root?(name, root), do: name == root or String.starts_with?(name, root <> "/")

  defp extract_contents(path) do
    case :erl_tar.extract(String.to_charlist(path), [:memory, :compressed]) do
      {:ok, entries} ->
        contents =
          Map.new(entries, fn {name, content} ->
            {IO.chardata_to_string(name), IO.iodata_to_binary(content)}
          end)

        {:ok, contents}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_content(contents, path) do
    case Map.fetch(contents, path) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, {:missing_archive_content, path}}
    end
  end

  defp parse_skill(skill_md) do
    case Loader.parse(skill_md) do
      {:ok, skill_entry} -> {:ok, skill_entry}
      {:error, reason} -> {:error, {:invalid_skill_md, reason}}
    end
  end

  defp read_meta(contents, meta_path) do
    case Map.fetch(contents, meta_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, meta} when is_map(meta) -> {:ok, meta}
          {:ok, _} -> {:error, :malformed_meta_json}
          {:error, _} -> {:error, :malformed_meta_json}
        end

      :error ->
        {:ok, %{}}
    end
  end
end
