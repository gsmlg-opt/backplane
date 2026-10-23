defmodule Backplane.Plugins.Sync do
  @moduledoc "Pinned repository and Codex marketplace synchronization with per-entry diagnostics."
  alias Backplane.Plugins
  alias Backplane.Plugins.{Git, Source}
  alias Backplane.Repo

  def run(source_id, opts \\ []) do
    result =
      Repo.transact(fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [
          "plugin-source:" <> source_id
        ])

        result =
          case Plugins.get_source(source_id) do
            nil -> {:error, :not_found}
            %Source{} = source -> sync(source, opts)
          end

        {:ok, result}
      end)

    case result do
      {:ok, result} -> result
      error -> error
    end
  end

  defp sync(source, opts) do
    now = DateTime.utc_now()
    Plugins.update_source(source, %{last_attempt_at: now})
    opts = Keyword.put(opts, :credential_name, source.credential_name)
    adapter = Keyword.get(opts, :adapter, Git)

    result =
      with {:ok, commit, files, modes} <- fetch_snapshot(adapter, source.url, source.ref, opts) do
        entries(source, files)
        |> case do
          {:ok, entries} -> import_entries(source, commit, files, modes, entries, adapter, opts)
          error -> error
        end
      end

    case result do
      {:ok, commit, releases, diagnostics} ->
        status = if diagnostics == [], do: "synced", else: "partial"
        attrs = %{status: status, diagnostics: diagnostics, source_commit: commit}
        attrs = if diagnostics == [], do: Map.put(attrs, :last_success_at, now), else: attrs
        {:ok, updated} = Plugins.update_source(Repo.get!(Source, source.id), attrs)
        {:ok, %{source: updated, releases: releases, diagnostics: diagnostics}}

      {:error, reason} ->
        diagnostic = diagnostic(nil, reason)

        Plugins.update_source(Repo.get!(Source, source.id), %{
          status: "failed",
          diagnostics: [diagnostic]
        })

        {:error, reason}
    end
  end

  defp entries(%Source{kind: "plugin", path: path}, _files),
    do: {:ok, [%{"path" => path}]}

  defp entries(source, files) do
    path = if source.path in [nil, ""], do: ".agents/plugins/marketplace.json", else: source.path

    with {:ok, bytes} <- Map.fetch(files, path),
         {:ok, %{"name" => name, "plugins" => plugins}}
         when is_binary(name) and name != "" and is_list(plugins) <- Jason.decode(bytes) do
      {:ok, plugins}
    else
      _ -> {:error, :invalid_marketplace}
    end
  end

  defp import_entries(source, catalog_commit, files, modes, entries, adapter, opts) do
    {releases, errors} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {entry, index}, {releases, errors} ->
        result =
          with :ok <- validate_entry(entry, source.kind),
               {:ok, commit, path, package, file_modes} <-
                 package(entry, source, catalog_commit, files, modes, adapter, opts),
               {:ok, release} <-
                 Plugins.import_files(package, %{
                   publisher: source.name,
                   file_modes: file_modes,
                   identity:
                     "source:" <>
                       source.id <> "/" <> (entry["id"] || entry["name"] || path),
                   source_id: source.id,
                   source_commit: commit,
                   source_path: path,
                   provenance: %{
                     "catalog_commit" => catalog_commit,
                     "source_url" => source.url,
                     "plugin_source_url" => plugin_url(entry, source)
                   }
                 }),
               {:ok, release} <- maybe_publish(source, release) do
            {:ok, release}
          end

        case result do
          {:ok, release} ->
            {[release | releases], errors}

          {:error, reason} ->
            {releases, [diagnostic("entry:#{index}", reason) | errors]}
        end
      end)

    {:ok, catalog_commit, Enum.reverse(releases), Enum.reverse(errors)}
  end

  defp package(entry, source, commit, files, modes, adapter, opts) do
    case entry["source"] do
      %{"source" => "github", "repo" => repo} = remote when is_binary(repo) ->
        remote_package("https://github.com/" <> repo, remote, adapter, opts)

      %{"source" => kind, "url" => url} = remote when kind in ["git", "url", "git-subdir"] ->
        remote_package(url, remote, adapter, opts)

      %{"type" => "git", "url" => url} = remote ->
        remote_package(url, remote, adapter, opts)

      %{"source" => "local", "path" => path} ->
        local_package(commit, files, modes, path)

      %{"type" => "local", "path" => path} ->
        local_package(commit, files, modes, path)

      path when is_binary(path) ->
        local_package(commit, files, modes, path)

      nil ->
        local_package(commit, files, modes, entry["path"] || source.path || "")

      _ ->
        {:error, :unsupported_marketplace_source}
    end
  end

  defp validate_entry(entry, kind) when is_map(entry) do
    cond do
      kind == "marketplace" and is_nil(entry["source"]) ->
        {:error, :invalid_marketplace_source}

      Enum.any?(["id", "name"], fn key ->
        Map.has_key?(entry, key) and not valid_identity?(entry[key])
      end) ->
        {:error, :invalid_plugin_identity}

      true ->
        :ok
    end
  end

  defp validate_entry(_, _), do: {:error, :invalid_marketplace_entry}

  defp valid_identity?(value) when is_binary(value) do
    byte_size(value) in 1..255 and String.valid?(value) and
      not Regex.match?(~r/[[:cntrl:]]/, value) and
      not String.contains?(value, "\\") and
      not String.starts_with?(value, "/") and
      Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_identity?(_), do: false

  defp remote_package(url, remote, adapter, opts) when is_binary(url) do
    selectors = [remote["sha"], remote["ref"], remote["path"], remote["subdir"]]

    if Enum.all?(
         selectors,
         &(is_nil(&1) or (is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>)))
       ) do
      with {:ok, path} <- normalize_path(remote["path"] || remote["subdir"] || ""),
           {:ok, commit, files, modes} <-
             fetch_snapshot(adapter, url, remote["sha"] || remote["ref"] || "HEAD", opts) do
        local_package(commit, files, modes, path)
      end
    else
      {:error, :invalid_marketplace_source}
    end
  end

  defp remote_package(_, _, _, _), do: {:error, :invalid_marketplace_source}

  defp local_package(commit, files, modes, path) do
    with {:ok, path} <- normalize_path(path) do
      prefix = if path == "", do: "", else: path <> "/"
      package = subtree(files, prefix)
      file_modes = subtree(modes, prefix)
      {:ok, commit, path, package, file_modes}
    end
  end

  defp normalize_path(path) when path in ["", ".", "./"], do: {:ok, ""}

  defp normalize_path(path) when is_binary(path) do
    normalized = path |> String.replace_prefix("./", "") |> String.trim_trailing("/")

    invalid =
      not String.valid?(path) or Path.type(path) == :absolute or
        String.contains?(path, ["\\", <<0>>]) or Regex.match?(~r/[[:cntrl:]]/, path) or
        Regex.match?(~r/\A[A-Za-z]:/, path) or
        Enum.any?(String.split(normalized, "/"), &(&1 in ["", ".", ".."]))

    if invalid, do: {:error, :unsafe_plugin_path}, else: {:ok, normalized}
  end

  defp normalize_path(_), do: {:error, :unsafe_plugin_path}

  defp subtree(files, prefix) do
    files
    |> Enum.filter(fn {file, _} -> String.starts_with?(file, prefix) end)
    |> Map.new(fn {file, bytes} -> {String.replace_prefix(file, prefix, ""), bytes} end)
  end

  defp fetch_snapshot(adapter, url, ref, opts) do
    Code.ensure_loaded!(adapter)

    if function_exported?(adapter, :snapshot_with_metadata, 3) do
      adapter.snapshot_with_metadata(url, ref, opts)
    else
      with {:ok, commit, files} <- adapter.snapshot(url, ref, opts), do: {:ok, commit, files, %{}}
    end
  end

  defp plugin_url(entry, source) do
    case entry["source"] do
      %{"source" => "github", "repo" => repo} when is_binary(repo) ->
        "https://github.com/" <> repo

      %{"source" => kind, "url" => url}
      when kind in ["git", "url", "git-subdir"] and is_binary(url) ->
        url

      %{"type" => "git", "url" => url} when is_binary(url) ->
        url

      _ ->
        source.url
    end
  end

  defp maybe_publish(%Source{auto_publish: true}, release),
    do: Plugins.publish_release(release.id)

  defp maybe_publish(_, release), do: {:ok, release}

  defp diagnostic(entry, reason),
    do: %{"entry" => entry, "code" => "sync_failed", "message" => safe_reason(reason)}

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({:git_failed, status}), do: "git_failed:#{status}"
  defp safe_reason(reason) when is_list(reason), do: "plugin_validation_failed"
  defp safe_reason(_), do: "sync_failed"
end
