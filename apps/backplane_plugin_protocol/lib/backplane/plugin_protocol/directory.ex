defmodule Backplane.PluginProtocol.Directory do
  @moduledoc false

  alias Backplane.PluginProtocol.Manifest
  alias Backplane.PluginProtocol.Path, as: PackagePath

  def read_manifest(root, opts) do
    case PackagePath.resolve(root, "plugin.json") do
      {:ok, path, %{type: :regular, size: size}} ->
        if size <= Keyword.get(opts, :max_file_bytes, 16_777_216) do
          case File.read(path) do
            {:ok, bytes} -> {:ok, bytes}
            {:error, reason} -> manifest_error(reason)
          end
        else
          {:error, :file_too_large}
        end

      {:error, :enoent} ->
        {:error,
         [Manifest.diag(:error, :missing_manifest, "plugin.json", "root plugin.json is required")]}

      other ->
        manifest_error(other)
    end
  end

  def read(root, manifest, opts) do
    snapshot = %{files: %{"plugin.json" => manifest}, diagnostics: [], count: 1}

    cond do
      Keyword.get(opts, :max_entries, 20_000) < 1 ->
        {:error, :too_many_entries}

      Keyword.get(opts, :max_depth, 64) < 1 ->
        {:error, :tree_too_deep}

      true ->
        with {:ok, snapshot} <- walk(root, "", root, [root], snapshot, opts) do
          {:ok, %{files: snapshot.files, diagnostics: Enum.reverse(snapshot.diagnostics)}}
        end
    end
  end

  defp walk(root, relative, resolved, ancestors, snapshot, opts) do
    case File.ls(resolved) do
      {:ok, children} ->
        Enum.reduce_while(Enum.sort(children), {:ok, snapshot}, fn child, {:ok, acc} ->
          path = if relative == "", do: child, else: relative <> "/" <> child

          case read_entry(root, path, ancestors, acc, opts) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
        end)

      {:error, reason} ->
        {:ok, deny(snapshot, relative, reason)}
    end
  end

  defp read_entry(_root, "plugin.json", _ancestors, snapshot, _opts), do: {:ok, snapshot}

  defp read_entry(root, relative, ancestors, snapshot, opts) do
    cond do
      snapshot.count >= Keyword.get(opts, :max_entries, 20_000) ->
        {:error, :too_many_entries}

      length(String.split(relative, "/")) > Keyword.get(opts, :max_depth, 64) ->
        {:error, :tree_too_deep}

      true ->
        snapshot = %{snapshot | count: snapshot.count + 1}
        read_resolved(root, relative, ancestors, snapshot, opts)
    end
  end

  defp read_resolved(root, relative, ancestors, snapshot, opts) do
    case PackagePath.resolve(root, relative) do
      {:ok, resolved, %{type: :directory}} ->
        snapshot =
          if relative == "mcp.json" or skill_document?(relative),
            do: deny(snapshot, relative, :not_regular_file),
            else: snapshot

        if resolved in ancestors do
          {:ok, deny(snapshot, relative, :directory_cycle)}
        else
          walk(root, relative, resolved, [resolved | ancestors], snapshot, opts)
        end

      {:ok, resolved, %{type: :regular, size: size}} ->
        if size <= Keyword.get(opts, :max_file_bytes, 16_777_216) do
          read_file(resolved, relative, snapshot, opts)
        else
          {:error, :file_too_large}
        end

      {:ok, _, _} ->
        {:ok, deny(snapshot, relative, :not_regular_file)}

      {:error, reason} ->
        {:ok, deny(snapshot, relative, reason)}
    end
  end

  defp read_file(resolved, relative, snapshot, opts) do
    case File.read(resolved) do
      {:ok, bytes} ->
        files = Map.put(snapshot.files, relative, bytes)
        with :ok <- PackagePath.validate_files(files, opts), do: {:ok, %{snapshot | files: files}}

      {:error, reason} ->
        {:ok, deny(snapshot, relative, reason)}
    end
  end

  defp skill_document?(path), do: match?(["skills", _, "SKILL.md"], String.split(path, "/"))

  defp deny(snapshot, path, reason) do
    code =
      case String.split(path, "/") do
        ["skills"] -> :invalid_skills_location
        ["mcp.json"] -> :invalid_mcp_location
        ["skills", _] -> :invalid_skill
        ["skills", _, "SKILL.md"] -> :invalid_skill
        _ -> :unsafe_package_path
      end

    diagnostic = Manifest.diag(:error, code, path, "package path unavailable: #{inspect(reason)}")
    %{snapshot | diagnostics: [diagnostic | snapshot.diagnostics]}
  end

  defp manifest_error(reason) do
    {:error,
     [
       Manifest.diag(
         :error,
         :invalid_manifest_location,
         "plugin.json",
         "manifest unavailable: #{inspect(reason)}"
       )
     ]}
  end
end
