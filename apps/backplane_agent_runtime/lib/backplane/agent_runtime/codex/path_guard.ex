defmodule Backplane.AgentRuntime.Codex.PathGuard do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Canonical, symlink-aware containment for Codex workspace paths.
  """

  @spec authorize(binary(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def authorize(root, path) when is_binary(root) and is_binary(path) do
    root_input = normalize(Path.expand(root))
    path_input = Path.expand(path, root_input)

    with :ok <- reject_nul(path),
         {:ok, root_real} <- resolve_existing(root_input),
         {:ok, expanded} <- map_to_real_root(root_input, root_real, path_input),
         :ok <- real_containment(root_real, expanded) do
      {:ok, expanded}
    end
  end

  def authorize(_root, _path), do: {:error, Error.new(:validation, "path is required")}

  defp normalize("/"), do: "/"
  defp normalize(path), do: String.trim_trailing(path, "/")

  defp map_to_real_root(root_input, root_real, path_input) do
    cond do
      path_input == root_input ->
        {:ok, root_real}

      String.starts_with?(path_input, root_input <> "/") ->
        {:ok, Path.join(root_real, Path.relative_to(path_input, root_input))}

      true ->
        lexical_containment(root_real, path_input)
    end
  end

  defp reject_nul(path) do
    if String.contains?(path, <<0>>),
      do: {:error, Error.new(:validation, "path contains NUL")},
      else: :ok
  end

  defp lexical_containment(root, path) do
    if path == root or String.starts_with?(path, root <> "/"),
      do: {:ok, path},
      else: {:error, Error.new(:forbidden, "path is outside authorized workspace")}
  end

  defp real_containment(root, path) do
    case resolve_existing(nearest_existing(path)) do
      {:ok, resolved} ->
        if resolved == root or String.starts_with?(resolved, root <> "/"),
          do: :ok,
          else: {:error, Error.new(:forbidden, "path resolves outside authorized workspace")}

      {:error, reason} ->
        {:error, Error.new(:resource_conflict, "path could not be resolved", cause: reason)}
    end
  end

  defp nearest_existing(path) do
    if File.exists?(path), do: path, else: nearest_existing(Path.dirname(path))
  end

  defp resolve_existing(path), do: resolve_components(Path.expand(path), 0)

  defp resolve_components(path, depth) when depth < 32 do
    {root, rest} =
      case Path.split(path) do
        ["/" | segments] -> {"/", segments}
        [first | segments] -> {first, segments}
      end

    resolve_components(root, rest, depth)
  end

  defp resolve_components(_path, _depth), do: {:error, :symlink_resolution_limit}
  defp resolve_components(current, [], _depth), do: {:ok, Path.expand(current)}

  defp resolve_components(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target = if Path.type(target) == :absolute, do: target, else: Path.join(current, target)
          resolve_components(target, rest, depth + 1)
        end

      {:ok, _stat} ->
        resolve_components(candidate, rest, depth)

      {:error, :enoent} ->
        {:ok, Path.join(candidate, Enum.join(rest, "/"))}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
