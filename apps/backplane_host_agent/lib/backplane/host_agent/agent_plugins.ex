defmodule Backplane.HostAgent.AgentPlugins do
  @moduledoc """
  Installs immutable Agent Plugins releases from a Backplane registry.

  Release directories are retained for rollback and existing runtime sessions.
  The writable data directory and host credential bindings outlive upgrades.
  Installation never starts MCP processes.
  """
  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.{Archive, Client}

  def install(client, plugin_id, opts \\ []) do
    params =
      %{plugin_id: plugin_id}
      |> maybe_put(:release_id, Keyword.get(opts, :release_id))
      |> maybe_put(:channel, Keyword.get(opts, :channel))

    with {:ok, descriptor} <- Client.resolve(client, params),
         {:ok, downloaded} <- Client.download(client, field(descriptor, :artifact_digest)) do
      install_archive(descriptor, downloaded.artifact, opts)
    end
  end

  def install_archive(descriptor, bytes, opts \\ []) do
    plugin_id = field(descriptor, :plugin_id)
    release_id = field(descriptor, :release_id)
    digest = field(descriptor, :artifact_digest)

    with true <- valid_id?(plugin_id) and valid_id?(release_id),
         true <- is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         true <- Archive.digest(bytes) == digest,
         {:ok, files} <- Archive.unpack(bytes),
         {:ok, _package} <- PluginProtocol.load(files) do
      base = plugin_dir(plugin_id, opts)

      :global.trans({{__MODULE__, base}, self()}, fn ->
        do_install(base, descriptor, bytes)
      end)
    else
      false -> {:error, :invalid_release_or_digest}
      error -> error
    end
  end

  def status(plugin_id, opts \\ []) do
    with :ok <- safe_directory(plugin_dir(plugin_id, opts), false),
         {:ok, bytes} <- File.read(Path.join(plugin_dir(plugin_id, opts), "installation.json")),
         {:ok, record} <- Jason.decode(bytes) do
      {:ok, installation(record)}
    end
  end

  def set_enabled(plugin_id, enabled, opts \\ []) when is_boolean(enabled) do
    base = plugin_dir(plugin_id, opts)

    :global.trans({{__MODULE__, base}, self()}, fn ->
      with {:ok, current} <- status(plugin_id, opts),
           record = current |> stringify() |> Map.put("enabled", enabled),
           :ok <- atomic_json(Path.join(base, "installation.json"), record) do
        {:ok, installation(record)}
      end
    end)
  end

  def rollback(plugin_id, release_id, opts \\ []) do
    base = plugin_dir(plugin_id, opts)

    :global.trans({{__MODULE__, base}, self()}, fn ->
      with {:ok, current} <- status(plugin_id, opts),
           record when not is_nil(record) <-
             Enum.find(current.history, &(field(&1, :release_id) == release_id)),
           {:ok, bytes} <-
             File.read(
               Path.join([base, "releases", field(record, :artifact_digest), "artifact.tar.gz"])
             ) do
        do_install(base, record, bytes)
      else
        nil -> {:error, :release_not_cached}
        error -> error
      end
    end)
  end

  @doc "Reports installation separately from component activation."
  def report(client, installation_id, installed, components \\ %{}) do
    Client.request(
      client,
      :post,
      "/installations/" <> URI.encode_www_form(installation_id) <> "/report",
      %{
        actual_release_id: installed.release_id,
        status: "installed",
        actual_enabled: installed.enabled,
        components: components
      }
    )
  end

  @doc "Prepares desired releases, then reports each result without enabling MCP."
  def reconcile(client, opts \\ []) do
    with {:ok, %{"data" => desired}} <- Client.request(client, :get, "/installations") do
      results =
        Enum.map(desired, fn item ->
          result =
            with {:ok, _installed} <-
                   install(
                     client,
                     item["plugin_id"],
                     Keyword.put(opts, :release_id, item["desired_release_id"])
                   ),
                 do: set_enabled(item["plugin_id"], item["enabled"] == true, opts)

          case result do
            {:ok, installed} ->
              {item["id"], report(client, item["id"], installed)}

            {:error, _} ->
              {item["id"],
               Client.request(client, :post, "/installations/" <> item["id"] <> "/report", %{
                 status: "failed",
                 components: %{"installation" => %{"status" => "failed"}}
               })}
          end
        end)

      {:ok, results}
    end
  end

  @doc "Generates a native Codex local marketplace from selected installed versions."
  def export_codex(directory, plugin_ids, opts \\ []) do
    stage = directory <> ".stage-" <> random_id()

    with false <- File.exists?(directory),
         :ok <- safe_directory(Path.dirname(Path.expand(directory))),
         :ok <- File.mkdir(stage) do
      result =
        Enum.reduce_while(plugin_ids, {:ok, []}, fn id, {:ok, entries} ->
          with {:ok, installed} <- status(id, opts),
               {:ok, package} <- PluginProtocol.load_directory(installed.root),
               {:ok, snapshot} <- Archive.read_directory_with_metadata(installed.root),
               {:ok, canonical} <- Archive.pack(snapshot.files, modes: snapshot.modes),
               true <- Archive.digest(canonical) == installed.content_digest,
               name = package.manifest["name"],
               false <- Enum.any?(entries, fn {entry, _mapping} -> entry["name"] == name end),
               target = Path.join([stage, "plugins", hash(id)]),
               :ok <- write_files(target, package.files, snapshot.modes) do
            entry = %{
              "name" => name,
              "source" => %{"source" => "local", "path" => "./plugins/" <> hash(id)},
              "description" => Map.get(package.manifest, "description", "")
            }

            mapping = %{
              plugin_id: id,
              release_id: installed.release_id,
              artifact_digest: installed.artifact_digest
            }

            {:cont, {:ok, entries ++ [{entry, mapping}]}}
          else
            true -> {:halt, {:error, :duplicate_codex_plugin_name}}
            false -> {:halt, {:error, :installed_content_changed}}
            error -> {:halt, error}
          end
        end)

      outcome =
        with {:ok, entries} <- result,
             :ok <-
               atomic_json(
                 Path.join([stage, ".agents", "plugins", "marketplace.json"]),
                 %{
                   name: Keyword.get(opts, :name, "backplane"),
                   plugins: Enum.map(entries, &elem(&1, 0))
                 }
               ),
             :ok <-
               atomic_json(
                 Path.join([stage, ".agents", "plugins", "backplane-releases.json"]),
                 Enum.map(entries, &elem(&1, 1))
               ),
             :ok <- File.rename(stage, directory) do
          {:ok, directory}
        end

      File.rm_rf(stage)
      outcome
    else
      true -> {:error, :destination_exists}
      error -> error
    end
  end

  defp do_install(base, descriptor, bytes) do
    digest = field(descriptor, :artifact_digest)

    with true <- Archive.digest(bytes) == digest,
         {:ok, snapshot} <- Archive.unpack_with_metadata(bytes),
         files = snapshot.files,
         {:ok, _package} <- PluginProtocol.load(files),
         :ok <- safe_directory(base),
         data_dir = Path.join(base, "data"),
         :ok <- safe_directory(data_dir),
         root = Path.join([base, "releases", digest, "plugin"]),
         :ok <- prepare_release(root, files, snapshot.modes, bytes),
         {:ok, canonical} <- Archive.pack(files, modes: snapshot.modes) do
      previous =
        case File.read(Path.join(base, "installation.json")) do
          {:ok, saved} -> Jason.decode!(saved)
          _ -> %{}
        end

      entry = %{
        "plugin_id" => field(descriptor, :plugin_id),
        "release_id" => field(descriptor, :release_id),
        "artifact_digest" => digest,
        "root" => root,
        "data_dir" => data_dir,
        "content_digest" => Archive.digest(canonical),
        "enabled" => Map.get(previous, "enabled", false)
      }

      history =
        [Map.drop(entry, ["history"]) | Map.get(previous, "history", [])]
        |> Enum.uniq_by(& &1["release_id"])

      record = Map.put(entry, "history", history)

      with :ok <- atomic_json(Path.join(base, "installation.json"), record) do
        {:ok, installation(record)}
      end
    else
      false -> {:error, :integrity_mismatch}
      error -> error
    end
  end

  defp prepare_release(root, files, modes, bytes) do
    with :ok <- safe_directory(root, false) do
      do_prepare_release(root, files, modes, bytes)
    end
  end

  defp do_prepare_release(root, files, modes, bytes) do
    if File.exists?(root) do
      with {:ok, snapshot} <- Archive.read_directory_with_metadata(root),
           true <- snapshot.files == files and snapshot.modes == modes do
        :ok
      else
        _ -> {:error, :cached_release_corrupt}
      end
    else
      parent = Path.dirname(root)
      stage = parent <> ".stage-" <> random_id()

      with :ok <- safe_directory(Path.dirname(parent)) do
        result =
          with :ok <- write_files(Path.join(stage, "plugin"), files, modes),
               :ok <- File.write(Path.join(stage, "artifact.tar.gz"), bytes, [:binary]),
               :ok <- File.rename(stage, parent),
               do: :ok

        File.rm_rf(stage)
        result
      end
    end
  end

  defp write_files(root, files, modes) do
    with :ok <- File.mkdir_p(root) do
      Enum.reduce_while(files, :ok, fn {relative, bytes}, :ok ->
        path = Path.join(root, relative)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, bytes, [:binary]),
             :ok <- File.chmod(path, Map.get(modes, relative, 0o644)) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  # Check each existing ancestor before creating owned directories.
  defp safe_directory(path, create? \\ true) do
    path = Path.expand(path)

    Enum.reduce_while(Path.split(path), {:ok, ""}, fn part, {:ok, parent} ->
      next = if parent == "", do: part, else: Path.join(parent, part)

      result =
        case File.lstat(next) do
          {:ok, %{type: :directory}} -> :ok
          {:error, :enoent} -> if create?, do: File.mkdir(next), else: :ok
          _ -> {:error, :unsafe_install_directory}
        end

      case result do
        :ok -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp atomic_json(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = path <> "." <> random_id()

      result =
        with :ok <- File.write(temp, Jason.encode!(data), [:binary, :exclusive]),
             :ok <- File.rename(temp, path),
             do: :ok

      File.rm(temp)
      result
    end
  end

  defp plugin_dir(id, opts),
    do: Path.join(Keyword.get(opts, :root, Path.expand("~/.backplane/plugins")), hash(id))

  defp hash(id), do: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..200
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp installation(map) do
    %{
      plugin_id: map["plugin_id"],
      release_id: map["release_id"],
      artifact_digest: map["artifact_digest"],
      content_digest: map["content_digest"],
      root: map["root"],
      data_dir: map["data_dir"],
      enabled: map["enabled"],
      history: Map.get(map, "history", [])
    }
  end
end
