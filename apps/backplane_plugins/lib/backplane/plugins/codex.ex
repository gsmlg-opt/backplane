defmodule Backplane.Plugins.Codex do
  @moduledoc "Exports selected immutable releases to a Codex native marketplace. Git publishing is explicit."
  alias Backplane.Plugins
  alias Backplane.Plugins.Git
  alias Backplane.PluginProtocol.Archive

  @doc "Build a local marketplace snapshot. The destination must not already exist."
  def export(destination, opts \\ []) do
    with {:ok, files, mapping} <- snapshot(opts),
         false <- File.exists?(destination) do
      stage = destination <> ".stage-" <> Ecto.UUID.generate()

      try do
        with :ok <- write_files(stage, files, export_modes(mapping)),
             :ok <- File.rename(stage, destination) do
          {:ok, %{directory: destination, releases: mapping}}
        end
      after
        File.rm_rf(stage)
      end
    else
      true -> {:error, :destination_exists}
      error -> error
    end
  end

  @doc "Return all files for a Codex marketplace snapshot without writing or publishing."
  def snapshot(opts \\ []) do
    catalog = Plugins.catalog(channel: Keyword.get(opts, :channel, "stable"))

    selected =
      case Keyword.get(opts, :plugin_ids) do
        nil -> catalog.data
        ids when is_list(ids) -> Enum.filter(catalog.data, &(&1.plugin_id in ids))
      end

    names = Enum.map(selected, & &1.manifest["name"])

    if length(names) == length(Enum.uniq(names)) do
      snapshot_releases(selected, opts)
    else
      {:error, :duplicate_codex_plugin_name}
    end
  end

  defp snapshot_releases(releases, opts) do
    Enum.reduce_while(releases, {:ok, %{}, [], []}, fn release, {:ok, files, entries, mapping} ->
      with {:ok, artifact} <- Plugins.artifact(release.plugin_id, release.release_id),
           {:ok, %{files: package, modes: modes}} <- Archive.unpack_with_metadata(artifact) do
        # UUID paths preserve independent identities; native Codex names must match manifests.
        path = "plugins/" <> release.plugin_id
        imported = Map.new(package, fn {name, bytes} -> {path <> "/" <> name, bytes} end)

        entry = %{
          "name" => release.manifest["name"],
          "source" => %{"source" => "local", "path" => "./" <> path}
        }

        report = %{
          plugin_id: release.plugin_id,
          identity: release.identity,
          release_id: release.release_id,
          artifact_digest: release.artifact_digest,
          path: path,
          file_modes: modes
        }

        {:cont, {:ok, Map.merge(files, imported), [entry | entries], [report | mapping]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, entries, mapping} ->
        marketplace = %{
          "name" => Keyword.get(opts, :name, "backplane"),
          "plugins" => Enum.reverse(entries)
        }

        files =
          files
          |> Map.put(".agents/plugins/marketplace.json", Jason.encode!(marketplace, pretty: true))
          |> Map.put(
            ".agents/plugins/backplane-releases.json",
            Jason.encode!(Enum.reverse(mapping), pretty: true)
          )

        {:ok, files, Enum.reverse(mapping)}

      error ->
        error
    end
  end

  @doc "Explicitly commit and push a marketplace to the configured HTTPS Git repository, using a vault credential."
  def publish_git(config, opts \\ []) do
    url = value(config, :url)
    branch = value(config, :branch, "main")
    opts = Keyword.put(opts, :credential_name, value(config, :credential_name))

    with {:ok, env} <- Git.publish_env(url, opts),
         {:ok, files, mapping} <- snapshot(opts) do
      Git.temporary(fn directory ->
        with {:ok, _} <-
               Git.command(
                 [
                   "clone",
                   "--quiet",
                   "--branch",
                   branch,
                   "--single-branch",
                   "--",
                   url,
                   directory
                 ],
                 env
               ),
             :ok <- clean_previous_snapshot(directory),
             :ok <- write_files(directory, files, export_modes(mapping)),
             {:ok, _} <-
               Git.command(
                 ["-C", directory, "add", "--force", "--", ".agents/plugins", "plugins"],
                 env
               ),
             {:ok, _} <-
               Git.command(
                 [
                   "-C",
                   directory,
                   "-c",
                   "user.name=Backplane",
                   "-c",
                   "user.email=backplane@localhost",
                   "commit",
                   "--allow-empty",
                   "--quiet",
                   "-m",
                   "Publish plugin marketplace"
                 ],
                 env
               ),
             {:ok, commit} <- Git.command(["-C", directory, "rev-parse", "HEAD"], env),
             {:ok, _} <-
               Git.command(
                 ["-C", directory, "push", "--", "origin", "HEAD:refs/heads/" <> branch],
                 env
               ) do
          {:ok, %{commit: String.trim(commit), releases: mapping}}
        end
      end)
    end
  end

  defp clean_previous_snapshot(directory) do
    path = Path.join(directory, ".agents/plugins/backplane-releases.json")

    with :ok <- safe_target(directory, ".agents/plugins/backplane-releases.json") do
      case File.read(path) do
        {:ok, bytes} ->
          with {:ok, entries} when is_list(entries) <- Jason.decode(bytes) do
            Enum.reduce_while(entries, :ok, fn entry, :ok ->
              case entry["path"] do
                "plugins/" <> id ->
                  case Ecto.UUID.cast(id) do
                    {:ok, _} ->
                      case safe_target(directory, "plugins/" <> id) do
                        :ok ->
                          File.rm_rf!(Path.join(directory, "plugins/" <> id))
                          {:cont, :ok}

                        error ->
                          {:halt, error}
                      end

                    _ ->
                      {:halt, {:error, :invalid_export_mapping}}
                  end

                _ ->
                  {:halt, {:error, :invalid_export_mapping}}
              end
            end)
          else
            _ -> {:error, :invalid_export_mapping}
          end

        {:error, :enoent} ->
          :ok

        error ->
          error
      end
    end
  end

  defp export_modes(mapping) do
    Enum.reduce(mapping, %{}, fn report, acc ->
      Map.merge(
        acc,
        Map.new(report.file_modes, fn {path, mode} -> {report.path <> "/" <> path, mode} end)
      )
    end)
  end

  defp write_files(directory, files, modes) do
    Enum.reduce_while(files, :ok, fn {path, bytes}, :ok ->
      target = Path.join(directory, path)

      with :ok <- safe_target(directory, path),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, bytes),
           :ok <- File.chmod(target, Map.get(modes, path, 0o644)) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp safe_target(directory, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while({:ok, directory}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %{type: type}} when type in [:directory, :regular] -> {:cont, {:ok, path}}
        {:error, :enoent} -> {:cont, {:ok, path}}
        _ -> {:halt, {:error, :unsafe_export_path}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
