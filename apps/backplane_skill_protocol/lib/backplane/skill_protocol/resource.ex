defmodule Backplane.SkillProtocol.Resource do
  @moduledoc "Boundary-checked reads from a prepared Skill; no content is executed."

  alias Backplane.SkillProtocol.{Error, PathSafety, PreparedSkill}

  @spec read(PreparedSkill.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def read(prepared, relative, opts \\ [])

  def read(%PreparedSkill{root: root, manifest: manifest}, relative, opts)
      when is_binary(relative) do
    with :ok <- safe_relative(relative),
         true <- Enum.any?(manifest.files, &(&1.path == relative)),
         {:ok, canonical_root} <- realpath(root),
         path = Path.expand(relative, root),
         :ok <- contained(path, root),
         {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, canonical_root),
         {:ok, stat} <- File.stat(canonical),
         :ok <- size_limit(stat.size, Keyword.get(opts, :max_bytes, 8 * 1024 * 1024)),
         {:ok, bytes} <- File.read(canonical) do
      {:ok, bytes}
    else
      false -> error(:not_found, "resource is not in the verified inventory")
      {:error, %Error{} = reason} -> {:error, reason}
      {:error, reason} -> error(:not_found, "resource cannot be read", %{reason: inspect(reason)})
    end
  end

  def read(_prepared, _relative, _opts), do: error(:invalid_request, "invalid resource request")

  defp safe_relative(path) do
    cond do
      path == "" or Path.type(path) == :absolute ->
        error(:invalid_request, "resource path is unsafe")

      String.contains?(path, "\\") ->
        error(:invalid_request, "resource path is unsafe")

      ".." in String.split(path, "/", trim: false) ->
        error(:invalid_request, "resource path is unsafe")

      Regex.match?(~r/(?:^|\/)[A-Za-z]:/, path) ->
        error(:invalid_request, "resource path is unsafe")

      true ->
        :ok
    end
  end

  defp realpath(path), do: PathSafety.realpath(path)

  defp contained(path, root) do
    root = Path.expand(root)

    if path == root or String.starts_with?(path, root <> "/"),
      do: :ok,
      else: error(:invalid_request, "resource escapes prepared root")
  end

  defp size_limit(size, max) when size <= max, do: :ok
  defp size_limit(_size, _max), do: error(:limit_exceeded, "resource exceeds read limit")

  defp error(code, message, context \\ %{}),
    do: {:error, Error.new(code, :resource, message, context: context)}
end
