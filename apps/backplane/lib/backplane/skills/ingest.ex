defmodule Backplane.Skills.Ingest do
  @moduledoc """
  Archive ingest pipeline for skills.
  """

  alias Backplane.Repo
  alias Backplane.Skills.Archive
  alias Backplane.Skills.Blob
  alias Backplane.Skills.Registry
  alias Backplane.Skills.Skill

  require Logger

  @doc "Ingest a skill archive from a path or Plug.Upload-like map."
  @spec ingest(String.t() | %{path: String.t()}, keyword() | map()) ::
          {:ok, Skill.t()} | {:error, term()}
  def ingest(path_or_upload, opts \\ []) do
    opts = normalize_opts(opts)
    blob_opts = Keyword.get(opts, :blob, [])
    archive_opts = Keyword.get(opts, :archive, [])

    with {:ok, path, filename} <- archive_path(path_or_upload),
         {:ok, bytes} <- File.read(path),
         content_hash = sha256(bytes),
         {:ok, inspected} <- Archive.inspect(path_or_upload, archive_opts),
         slug = resolve_slug(inspected, filename),
         :changed <- ingest_state(slug, content_hash),
         {:ok, archive_ref} <- Blob.put(bytes, blob_opts),
         attrs = build_attrs(inspected, slug, content_hash, archive_ref),
         {:ok, skill} <- transact_upsert(attrs, archive_ref, blob_opts) do
      Registry.refresh()
      {:ok, skill}
    else
      {:unchanged, %Skill{} = skill} -> {:ok, skill}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts) when is_list(opts), do: opts

  defp archive_path(path) when is_binary(path), do: {:ok, path, Path.basename(path)}

  defp archive_path(%{path: path} = upload) when is_binary(path) do
    {:ok, path, Map.get(upload, :filename) || Map.get(upload, "filename") || Path.basename(path)}
  end

  defp archive_path(_), do: {:error, :invalid_archive_path}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ingest_state(slug, content_hash) do
    case Repo.get_by(Skill, slug: slug) do
      nil ->
        :changed

      %Skill{} = skill ->
        archive_ingest_state(skill, slug, content_hash)
    end
  end

  defp archive_ingest_state(%Skill{} = skill, slug, content_hash) do
    cond do
      not archive_backed?(skill) -> {:error, {:slug_conflict, slug}}
      skill.content_hash == content_hash -> {:unchanged, skill}
      true -> :changed
    end
  end

  defp archive_backed?(%Skill{id: "skill/" <> _, source_kind: "archive"}), do: true
  defp archive_backed?(_skill), do: false

  defp build_attrs(inspected, slug, content_hash, archive_ref) do
    entry = inspected.skill_entry
    meta = inspected.meta

    %{
      id: "skill/#{slug}",
      slug: slug,
      name: entry.name,
      description: entry.description || "",
      tags: entry.tags || [],
      content: entry.content,
      content_hash: content_hash,
      enabled: true,
      version: entry.version || string_meta(meta, "version"),
      license: entry.license || string_meta(meta, "license"),
      homepage: entry.homepage || string_meta(meta, "homepage"),
      author: entry.author || string_meta(meta, "author"),
      meta: meta,
      archive_ref: archive_ref,
      size_bytes: inspected.size_bytes,
      file_count: inspected.file_count,
      source_kind: "archive"
    }
  end

  defp resolve_slug(%{meta: meta, skill_entry: entry}, filename) do
    [
      string_meta(meta, "slug"),
      entry.name,
      archive_filename_root(filename)
    ]
    |> Enum.map(&slugify/1)
    |> Enum.find("skill", &(&1 != ""))
  end

  defp string_meta(meta, key) do
    case Map.get(meta, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp archive_filename_root(filename) do
    filename = Path.basename(to_string(filename))

    case Regex.run(~r/\A(.+)\.tar\.gz\z/i, filename) do
      [_match, root] -> root
      nil -> Path.rootname(filename)
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slugify(_), do: ""

  defp transact_upsert(attrs, archive_ref, blob_opts) do
    case Repo.transact(fn -> upsert(attrs) end) do
      {:ok, skill} ->
        {:ok, skill}

      {:error, reason} ->
        cleanup_unreferenced_blob(archive_ref, blob_opts)
        {:error, reason}
    end
  rescue
    exception ->
      cleanup_unreferenced_blob(archive_ref, blob_opts)
      {:error, exception}
  end

  defp cleanup_unreferenced_blob(archive_ref, blob_opts) do
    unless Repo.get_by(Skill, archive_ref: archive_ref) do
      case Blob.delete(archive_ref, blob_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to cleanup skill archive blob #{archive_ref}: #{inspect(reason)}"
          )
      end
    end
  end

  defp upsert(attrs) do
    case Repo.get_by(Skill, slug: attrs.slug) do
      nil ->
        %Skill{}
        |> Skill.changeset(attrs)
        |> Repo.insert()

      %Skill{} = skill ->
        skill
        |> Skill.changeset(attrs)
        |> Repo.update()
    end
  end
end
