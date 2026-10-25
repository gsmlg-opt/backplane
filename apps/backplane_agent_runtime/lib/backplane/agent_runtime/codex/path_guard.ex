defmodule Backplane.AgentRuntime.Codex.PathGuard do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Canonical, symlink-aware containment for Codex workspace paths.

  Write authorization also rejects multiply linked regular targets. These checks
  inspect the current filesystem; they do not provide race-free OS isolation.
  Hosts requiring protection from concurrent hostile filesystem changes must use
  an operating-system sandbox in addition to these checks.
  """

  @spec authorize(binary(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def authorize(root, path) when is_binary(root) and is_binary(path) do
    with :ok <- reject_nul(root),
         :ok <- reject_nul(path) do
      root_input = Path.expand(root)
      lexical = Path.expand(path, root_input)
      input = if Path.type(path) == :absolute, do: path, else: Path.join(root, path)

      with {:ok, root_real} <- resolve(root),
           :ok <- lexical_containment(root_input, root_real, lexical),
           {:ok, resolved} <- resolve(input),
           :ok <- containment(root_real, resolved),
           authorized = map_root(root_input, root_real, lexical),
           {:ok, target} <- resolve(authorized),
           :ok <- containment(root_real, target) do
        {:ok, authorized}
      end
    end
  end

  def authorize(_root, _path), do: {:error, Error.new(:validation, "path is required")}

  @doc "Checks containment and the current regular-file link count before a write."
  @spec authorize_write(binary(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def authorize_write(root, path) do
    with {:ok, resolved} <- authorize(root, path),
         :ok <- single_writer_target(resolved) do
      {:ok, resolved}
    end
  end

  defp single_writer_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, links: links}} when links > 1 ->
        {:error, Error.new(:forbidden, "write target has multiple hard links")}

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        resolution_error(reason)
    end
  end

  # Preserve the final directory entry (notably delete/rename of an inward
  # symlink). Both the original traversal and returned pathname are checked.
  defp map_root(root_input, root_real, path) do
    cond do
      path == root_input -> root_real
      contained?(root_input, path) -> Path.join(root_real, Path.relative_to(path, root_input))
      true -> path
    end
  end

  defp reject_nul(path) do
    if String.contains?(path, <<0>>),
      do: {:error, Error.new(:validation, "path contains NUL")},
      else: :ok
  end

  defp lexical_containment(root_input, root_real, path) do
    if contained?(root_input, path) or contained?(root_real, path),
      do: :ok,
      else: {:error, Error.new(:forbidden, "path is outside authorized workspace")}
  end

  defp containment(root, path) do
    if contained?(root, path),
      do: :ok,
      else: {:error, Error.new(:forbidden, "path resolves outside authorized workspace")}
  end

  defp contained?("/", _path), do: true
  defp contained?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  # Do not expand '..' before following links: a link target can itself contain a
  # link followed by '..'. lstat also sees dangling links, unlike File.exists?.
  defp resolve(path) do
    absolute = if Path.type(path) == :absolute, do: path, else: Path.join(File.cwd!(), path)

    case resolve_components("/", tl(Path.split(absolute)), 0) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> resolution_error(reason)
    end
  end

  defp resolve_components(_current, _rest, depth) when depth > 32,
    do: {:error, :symlink_resolution_limit}

  defp resolve_components(current, [], _depth), do: {:ok, current}

  defp resolve_components(current, ["." | rest], depth),
    do: resolve_components(current, rest, depth)

  defp resolve_components(current, [".." | rest], depth),
    do: resolve_components(Path.dirname(current), rest, depth)

  defp resolve_components(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          {base, segments} =
            if Path.type(target) == :absolute,
              do: {"/", tl(Path.split(target))},
              else: {current, Path.split(target)}

          resolve_components(base, segments ++ rest, depth + 1)
        end

      {:ok, _stat} ->
        resolve_components(candidate, rest, depth)

      {:error, :enoent} ->
        resolve_components(candidate, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolution_error(reason),
    do: {:error, Error.new(:resource_conflict, "path could not be resolved", cause: reason)}
end
