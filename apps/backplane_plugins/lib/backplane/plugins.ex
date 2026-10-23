defmodule Backplane.Plugins do
  @moduledoc "Immutable plugin publication, selected channels and consumer installation reports."
  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.Archive
  alias Backplane.Plugins.{Channel, Installation, Plugin, Release, Source}

  def list_plugins(_opts \\ []), do: Repo.all(from p in Plugin, order_by: p.identity)
  def get_plugin(id), do: get(Plugin, id)
  def get_installation(id), do: get(Installation, id)
  def get_release(id), do: get(Release, id)

  def list_releases(plugin_id),
    do:
      Repo.all(
        from r in Release, where: r.plugin_id == ^plugin_id, order_by: [desc: r.inserted_at]
      )

  def list_channels, do: Repo.all(from c in Channel, order_by: [c.name, c.plugin_id])
  def list_sources, do: Repo.all(from s in Source, order_by: s.name)
  def get_source(id), do: get(Source, id)
  def create_source(attrs), do: %Source{} |> Source.changeset(attrs) |> Repo.insert()

  def update_source(%Source{} = source, attrs),
    do: source |> Source.changeset(attrs) |> Repo.update()

  def delete_source(%Source{} = source), do: Repo.delete(source)
  def sync_source(id, opts \\ []), do: Backplane.Plugins.Sync.run(id, opts)

  def import_archive(bytes, attrs \\ %{}) when is_binary(bytes) do
    with {:ok, %{files: files, modes: modes}} <- Archive.unpack_with_metadata(bytes),
         do: import_files(files, Map.put(attrs, :file_modes, modes))
  end

  def import_files(files, attrs \\ %{}) do
    with {:ok, package} <- PluginProtocol.load(files),
         {:ok, artifact} <- Archive.pack(files, modes: value(attrs, :file_modes, %{})) do
      manifest = package.manifest
      publisher = value(attrs, :publisher, "local")
      identity = value(attrs, :identity, publisher <> "/" <> manifest["name"])
      digest = Archive.digest(artifact)
      commit = value(attrs, :source_commit)

      Repo.transact(fn ->
        lock("plugin:" <> identity)

        plugin =
          Repo.get_by(Plugin, identity: identity) ||
            unwrap(
              Repo.insert(
                Plugin.changeset(%Plugin{}, %{
                  identity: identity,
                  publisher: publisher,
                  name: manifest["name"],
                  source_id: value(attrs, :source_id)
                })
              )
            )

        query =
          from r in Release, where: r.plugin_id == ^plugin.id and r.artifact_digest == ^digest

        query =
          if is_nil(commit),
            do: where(query, [r], is_nil(r.source_commit)),
            else: where(query, [r], r.source_commit == ^commit)

        existing = Repo.one(query)

        release =
          existing ||
            unwrap(
              Repo.insert(
                Release.changeset(%Release{}, %{
                  plugin_id: plugin.id,
                  manifest: manifest,
                  raw_manifest: Map.fetch!(files, "plugin.json"),
                  upstream_version: manifest["version"],
                  artifact: artifact,
                  artifact_digest: digest,
                  source_commit: commit,
                  source_path:
                    if(value(attrs, :source_path) == "",
                      do: ".",
                      else: value(attrs, :source_path)
                    ),
                  provenance: value(attrs, :provenance, %{}),
                  diagnostics: json(package.diagnostics)
                })
              )
            )

        {:ok, release}
      end)
    end
  end

  @doc "Compose from exact immutable skill revisions, including every file in each bundle."
  def compose(manifest, selections, files \\ %{}, attrs \\ %{}) do
    initial_modes = value(attrs, :file_modes, %{})

    Enum.reduce_while(selections, {:ok, files, initial_modes}, fn selection, {:ok, acc, modes} ->
      case skill_files(selection) do
        {:ok, skill_files, skill_modes} ->
          if Enum.any?(Map.keys(skill_files), &Map.has_key?(acc, &1)),
            do: {:halt, {:error, :component_collision}},
            else: {:cont, {:ok, Map.merge(acc, skill_files), Map.merge(modes, skill_modes)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, composed, modes} ->
        import_files(
          Map.put(composed, "plugin.json", Jason.encode!(manifest)),
          Map.put(attrs, :file_modes, modes)
        )

      error ->
        error
    end
  end

  def publish_release(release_id, channel \\ "stable") do
    Repo.transact(fn ->
      release = get_release(release_id) || Repo.rollback(:not_found)
      lock("plugin:" <> release.plugin_id)

      release =
        if release.published_at,
          do: release,
          else:
            unwrap(Repo.update(Ecto.Changeset.change(release, published_at: DateTime.utc_now())))

      current = Repo.get_by(Channel, plugin_id: release.plugin_id, name: channel) || %Channel{}

      unwrap(
        Repo.insert_or_update(
          Channel.changeset(current, %{
            plugin_id: release.plugin_id,
            release_id: release.id,
            name: channel
          })
        )
      )

      {:ok, release}
    end)
  end

  def catalog(opts \\ []) do
    channel = Keyword.get(opts, :channel, "stable")

    rows =
      Repo.all(
        from p in Plugin,
          join: c in Channel,
          on: c.plugin_id == p.id,
          join: r in Release,
          on: r.id == c.release_id,
          where: c.name == ^channel,
          order_by: p.identity,
          select: {p, r}
      )

    %{data: Enum.map(rows, fn {p, r} -> descriptor(p, r) end), next_cursor: nil}
  end

  def resolve(plugin_id, release_id \\ nil, opts \\ []) do
    with %Plugin{} = plugin <- get_plugin(plugin_id),
         %Release{} = release <- selected_release(plugin.id, release_id, opts),
         true <- release.plugin_id == plugin.id and not is_nil(release.published_at) do
      {:ok, descriptor(plugin, release)}
    else
      _ -> {:error, :not_found}
    end
  end

  def artifact(plugin_id, release_id) do
    with {:ok, descriptor} <- resolve(plugin_id, release_id),
         do: artifact_by_digest(descriptor.artifact_digest)
  end

  def artifact_by_digest(digest) do
    release =
      Repo.one(
        from r in Release,
          where: r.artifact_digest == ^digest and not is_nil(r.published_at),
          limit: 1
      )

    case release do
      nil ->
        {:error, :not_found}

      release ->
        if Archive.digest(release.artifact) == digest,
          do: {:ok, release.artifact},
          else: {:error, :integrity_mismatch}
    end
  end

  def list_installations(opts \\ []) do
    query = from i in Installation, order_by: [asc: i.target, asc: i.plugin_id]

    query =
      if target = Keyword.get(opts, :target),
        do: where(query, [i], i.target == ^target),
        else: query

    Repo.all(query)
  end

  def set_desired(target, plugin_id, release_id, attrs \\ %{}) do
    with {:ok, _} <- resolve(plugin_id, release_id) do
      Repo.transact(fn ->
        lock("installation:" <> target <> ":" <> plugin_id)

        installation =
          Repo.get_by(Installation, target: target, plugin_id: plugin_id) || %Installation{}

        attrs = %{
          target: target,
          plugin_id: plugin_id,
          desired_release_id: release_id,
          enabled: value(attrs, :enabled, true)
        }

        {:ok, unwrap(Repo.insert_or_update(Installation.changeset(installation, attrs)))}
      end)
    end
  end

  def report_installation(id, attrs) do
    case get(Installation, id) do
      nil ->
        {:error, :not_found}

      installation ->
        actual = value(attrs, :actual_release_id, installation.actual_release_id)

        with :ok <- check_actual(installation.plugin_id, actual) do
          installation
          |> Installation.changeset(%{
            actual_release_id: actual,
            status: value(attrs, :status, "installed"),
            actual_enabled:
              value(attrs, :actual_enabled, value(attrs, :enabled, installation.actual_enabled)),
            components: safe_components(value(attrs, :components, installation.components)),
            diagnostics: safe_diagnostics(value(attrs, :diagnostics, installation.diagnostics)),
            reported_at: DateTime.utc_now()
          })
          |> Repo.update()
        end
    end
  end

  defp safe_components(components) when is_map(components) do
    Map.new(components, fn {name, report} ->
      status = if is_map(report), do: value(report, :status), else: report

      status =
        if is_binary(status) or is_atom(status),
          do: to_string(status || "unavailable"),
          else: "unavailable"

      status =
        if status in ~w(ready available unavailable pending installed enabled disabled failed authentication_required),
          do: status,
          else: "unavailable"

      {to_string(name), %{"status" => status}}
    end)
  end

  defp safe_components(_), do: %{}

  defp safe_diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.map(diagnostics, fn _ ->
      %{"code" => "consumer_report", "message" => "Consumer reported a component issue"}
    end)
  end

  defp safe_diagnostics(_), do: []

  defp check_actual(_plugin_id, nil), do: :ok

  defp check_actual(plugin_id, release_id) do
    case resolve(plugin_id, release_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp selected_release(plugin_id, nil, opts) do
    channel = Keyword.get(opts, :channel, "stable")

    Repo.one(
      from r in Release,
        join: c in Channel,
        on: c.release_id == r.id,
        where: c.plugin_id == ^plugin_id and c.name == ^channel
    )
  end

  defp selected_release(_plugin_id, id, _opts), do: get_release(id)

  defp descriptor(plugin, release) do
    %{
      plugin_id: plugin.id,
      identity: plugin.identity,
      publisher: plugin.publisher,
      name: plugin.name,
      release_id: release.id,
      manifest: release.manifest,
      upstream_version: release.upstream_version,
      artifact_digest: release.artifact_digest,
      artifact_url: "/plugin-protocol/v1/artifacts/" <> release.artifact_digest,
      source_commit: release.source_commit,
      source_path: release.source_path,
      diagnostics: release.diagnostics,
      published_at: release.published_at
    }
  end

  defp skill_files(selection) do
    id = value(selection, :skill_id)
    revision = value(selection, :revision)
    name = value(selection, :name)

    if is_binary(revision) and is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, name) do
      with {:ok, bytes} <- Backplane.Skills.Publication.artifact(id, revision) do
        dir = Path.join(System.tmp_dir!(), "plugin-skill-" <> Ecto.UUID.generate())
        File.mkdir_p!(dir)
        path = Path.join(dir, "skill.tar.gz")

        try do
          File.write!(path, bytes)

          with {:ok, bundle} <- Backplane.Skills.Publication.inspect_archive(path, id) do
            {:ok, entries} = :erl_tar.table(String.to_charlist(path), [:verbose, :compressed])

            entrypoint =
              Enum.find(entries, fn {path, type, _, _, _, _, _} ->
                type == :regular and Path.basename(to_string(path)) == "SKILL.md"
              end)

            root = entrypoint |> elem(0) |> to_string() |> Path.dirname()

            modes =
              entries
              |> Enum.filter(fn {_, type, _, _, _, _, _} -> type == :regular end)
              |> Map.new(fn {path, _, _, _, mode, _, _} ->
                {"skills/" <> name <> "/" <> Path.relative_to(to_string(path), root),
                 Bitwise.band(mode, 0o777)}
              end)

            {:ok,
             Map.new(bundle.files, fn {path, bytes} ->
               {"skills/" <> name <> "/" <> path, bytes}
             end), modes}
          end
        after
          File.rm_rf!(dir)
        end
      end
    else
      {:error, :exact_skill_revision_required}
    end
  end

  defp get(schema, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(schema, id)
      :error -> nil
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp lock(value),
    do: Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [value])

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
