defmodule Backplane.PluginProtocol.Path do
  @moduledoc "Portable package paths. File maps and archives contain regular files only."

  alias Elixir.Path, as: FilePath

  @doc false
  def resolve_root(root) do
    with {:ok, resolved, %{type: :directory}} <-
           resolve_parts("", FilePath.split(FilePath.absname(root)), 0) do
      {:ok, resolved}
    else
      {:ok, _, _} -> {:error, :not_directory}
      error -> error
    end
  end

  @doc false
  def resolve(root, relative) do
    with true <- safe?(relative),
         {:ok, resolved, stat} <- resolve_parts(root, String.split(relative, "/"), 0),
         true <-
           resolved == root or
             String.starts_with?(resolved, String.trim_trailing(root, "/") <> "/") do
      {:ok, resolved, stat}
    else
      false -> {:error, :outside_plugin_root}
      error -> error
    end
  end

  defp resolve_parts(_current, _parts, links) when links > 40,
    do: {:error, :too_many_symlinks}

  defp resolve_parts(current, [], _links) do
    with {:ok, stat} <- File.lstat(current), do: {:ok, current, stat}
  end

  defp resolve_parts(current, [part | rest], links) when part in ["", "."],
    do: resolve_parts(current, rest, links)

  defp resolve_parts(current, [".." | rest], links),
    do: resolve_parts(FilePath.dirname(current), rest, links)

  defp resolve_parts(current, [part | rest], links) do
    next = if FilePath.type(part) == :absolute, do: part, else: FilePath.join(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
          resolve_parts(current, FilePath.split(target) ++ rest, links + 1)
        end

      {:ok, %{type: :directory}} ->
        resolve_parts(next, rest, links)

      {:ok, stat} when rest == [] ->
        {:ok, next, stat}

      {:ok, _} ->
        {:error, :enotdir}

      error ->
        error
    end
  end

  def safe?(path) when is_binary(path) do
    String.valid?(path) and path != "" and byte_size(path) <= 4096 and
      not String.contains?(path, ["\\", "\0", ":"]) and
      not String.starts_with?(path, "/") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def safe?(_), do: false

  def contained?(path) when is_binary(path) do
    not String.contains?(path, ["\\", "\0", ":"]) and
      not String.starts_with?(path, "/") and
      Enum.reduce_while(String.split(path, "/"), 0, fn
        "..", 0 -> {:halt, :escape}
        "..", depth -> {:cont, depth - 1}
        segment, depth when segment in ["", "."] -> {:cont, depth}
        _, depth -> {:cont, depth + 1}
      end) != :escape
  end

  def contained?(_), do: false

  def validate_files(files, opts \\ []) do
    cond do
      not is_map(files) ->
        {:error, :invalid_files}

      map_size(files) > Keyword.get(opts, :max_files, 10_000) ->
        {:error, :too_many_files}

      Enum.any?(files, fn {path, bytes} -> not safe?(path) or not is_binary(bytes) end) ->
        {:error, :unsafe_file}

      Enum.any?(files, fn {path, _} ->
        path
        |> String.split("/")
        |> Enum.drop(-1)
        |> prefixes()
        |> Enum.any?(&Map.has_key?(files, &1))
      end) ->
        {:error, :file_directory_conflict}

      Enum.any?(files, fn {_, bytes} ->
        byte_size(bytes) > Keyword.get(opts, :max_file_bytes, 16_777_216)
      end) ->
        {:error, :file_too_large}

      Enum.reduce(files, 0, fn {_, bytes}, n -> n + byte_size(bytes) end) >
          Keyword.get(opts, :max_total_bytes, 67_108_864) ->
        {:error, :package_too_large}

      true ->
        :ok
    end
  end

  defp prefixes(parts) do
    parts |> Enum.scan(fn part, prefix -> prefix <> "/" <> part end)
  end
end
