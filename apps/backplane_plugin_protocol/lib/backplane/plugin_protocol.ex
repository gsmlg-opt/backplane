defmodule Backplane.PluginProtocol do
  @moduledoc """
  Offline Agent Plugins 1.0.0 loading with component-level diagnostics.

  `files` is a map of portable relative paths to regular-file bytes. Unknown
  metadata and extension files remain in the snapshot but acquire no semantics.
  The loader never launches a process, fetches a schema, or binds credentials.
  """
  alias Backplane.PluginProtocol.{Directory, Manifest, MCP, Skill}

  def load(files, opts \\ []) do
    with :ok <- Backplane.PluginProtocol.Path.validate_files(files, opts),
         {:ok, manifest} <- decode_manifest(files),
         {:ok, diagnostics} <- Manifest.validate(manifest) do
      {skills, skill_diagnostics} = discover_skills(files)
      {servers, mcp_diagnostics} = discover_mcp(files, opts)

      {:ok,
       %{
         manifest: manifest,
         skills: skills,
         mcp_servers: servers,
         files: files,
         diagnostics: diagnostics ++ skill_diagnostics ++ mcp_diagnostics
       }}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [Manifest.diag(:error, reason, "", "invalid package files")]}
    end
  end

  @doc """
  Loads a stable directory tree with component-level path failure boundaries.

  Safe links are resolved within the filesystem-resolved plugin root and their
  bytes use the original package-relative keys. Escaping resources are omitted;
  escaping manifests reject the plugin. This is distinct from the strict archive
  snapshot readers, which reject links. Callers must keep the tree stable while
  loading; this reader is not an OS sandbox against concurrent mutation.
  """
  def load_directory(root, opts \\ []) do
    with {:ok, resolved_root} <- Backplane.PluginProtocol.Path.resolve_root(root),
         {:ok, manifest} <- Directory.read_manifest(resolved_root, opts),
         {:ok, _} <- load(%{"plugin.json" => manifest}, opts),
         {:ok, snapshot} <- Directory.read(resolved_root, manifest, opts),
         {:ok, package} <- load(snapshot.files, opts) do
      directory_diagnostics =
        snapshot.diagnostics
        |> Enum.uniq_by(&{&1.code, &1.path})
        |> Enum.reject(fn diagnostic ->
          Enum.any?(
            package.diagnostics,
            &(&1.code == diagnostic.code and &1.path == diagnostic.path)
          )
        end)

      {:ok, %{package | diagnostics: package.diagnostics ++ directory_diagnostics}}
    else
      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, diagnostics}

      {:error, reason} ->
        {:error,
         [Manifest.diag(:error, :unsafe_directory, "", "cannot read package: #{inspect(reason)}")]}
    end
  end

  defp decode_manifest(files) do
    case Map.fetch(files, "plugin.json") do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, manifest} ->
            {:ok, manifest}

          _ ->
            {:error,
             [
               Manifest.diag(
                 :error,
                 :invalid_manifest_json,
                 "plugin.json",
                 "manifest must be valid JSON"
               )
             ]}
        end

      :error ->
        {:error,
         [Manifest.diag(:error, :missing_manifest, "plugin.json", "root plugin.json is required")]}
    end
  end

  defp discover_skills(files) do
    if Map.has_key?(files, "skills") do
      {[],
       [Manifest.diag(:error, :invalid_skills_location, "skills", "skills must be a directory")]}
    else
      files
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {path, bytes}, {skills, diagnostics} ->
        case String.split(path, "/") do
          ["skills", _, "SKILL.md"] ->
            case Skill.parse(path, bytes, files) do
              {:ok, skill} -> {skills ++ [skill], diagnostics}
              {:error, diagnostic} -> {skills, diagnostics ++ [diagnostic]}
            end

          _ ->
            {skills, diagnostics}
        end
      end)
    end
  end

  defp discover_mcp(files, opts) do
    if Enum.any?(Map.keys(files), &String.starts_with?(&1, "mcp.json/")) do
      {%{},
       [
         Manifest.diag(
           :error,
           :invalid_mcp_location,
           "mcp.json",
           "mcp.json must be a regular file"
         )
       ]}
    else
      MCP.discover(files["mcp.json"], opts)
    end
  end
end
