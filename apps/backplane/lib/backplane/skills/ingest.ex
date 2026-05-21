defmodule Backplane.Skills.Ingest do
  @moduledoc """
  Ingest pipeline for archived skills.
  """

  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Skills.{Archive, Skill}
  alias Backplane.Skills.Blob.LocalFS

  @spec ingest(binary(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def ingest(archive, opts \\ []) when is_binary(archive) do
    hash = hash(archive)

    with :ok <- validate_size(archive),
         {:ok, info} <- inspect_archive(archive, opts),
         attrs <- attrs_from_info(info, hash) do
      commit(archive, hash, attrs)
    end
  end

  defp inspect_archive(archive, opts) do
    Archive.inspect(archive,
      max_files: Settings.get("skills.archive.max_files") || 500,
      slug_fallback: filename_slug(Keyword.get(opts, :filename))
    )
  end

  defp validate_size(archive) do
    max_bytes = Settings.get("skills.archive.max_bytes") || 20_000_000

    if byte_size(archive) > max_bytes, do: {:error, :too_large}, else: :ok
  end

  defp commit(archive, hash, attrs) do
    case Repo.get_by(Skill, slug: attrs.slug) do
      %Skill{content_hash: ^hash} = skill ->
        {:ok, skill}

      existing ->
        blob_preexisted? = LocalFS.exists?(hash)

        with :ok <- LocalFS.put(hash, [archive]),
             {:ok, skill} <- upsert(existing, attrs) do
          Backplane.Skills.Registry.refresh()
          {:ok, skill}
        else
          {:error, reason} = error ->
            unless blob_preexisted?, do: LocalFS.delete(hash)
            if match?(%Ecto.Changeset{}, reason), do: error, else: {:error, reason}
        end
    end
  end

  defp upsert(nil, attrs) do
    attrs = Map.put(attrs, :id, "skill/#{attrs.slug}")

    Repo.transaction(fn ->
      %Skill{}
      |> Skill.changeset(attrs)
      |> Repo.insert()
      |> unwrap_transaction()
    end)
    |> unwrap_repo_transaction()
  end

  defp upsert(%Skill{} = skill, attrs) do
    attrs = Map.put(attrs, :id, skill.id)

    Repo.transaction(fn ->
      skill
      |> Skill.changeset(attrs)
      |> Repo.update()
      |> unwrap_transaction()
    end)
    |> unwrap_repo_transaction()
  end

  defp unwrap_transaction({:ok, skill}), do: skill
  defp unwrap_transaction({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_repo_transaction({:ok, skill}), do: {:ok, skill}
  defp unwrap_repo_transaction({:error, reason}), do: {:error, reason}

  defp attrs_from_info(info, hash) do
    entry = info.skill_entry
    meta = info.meta || %{}
    source = Map.get(meta, "source", %{}) || %{}

    %{
      slug: entry.slug,
      name: entry.name,
      description: entry.description || "",
      tags: entry.tags || [],
      content: entry.content,
      content_hash: hash,
      version: Map.get(meta, "version"),
      license: Map.get(meta, "license"),
      homepage: Map.get(meta, "homepage"),
      author: Map.get(meta, "author"),
      meta: meta,
      archive_ref: archive_ref(hash),
      size_bytes: info.size_bytes,
      file_count: info.file_count,
      source_kind: Map.get(source, "kind"),
      source_uri: Map.get(source, "uri"),
      source_rev: Map.get(source, "rev"),
      enabled: true
    }
  end

  defp hash(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
  defp archive_ref(hash), do: "sha256/#{hash}.tar.gz"

  defp filename_slug(nil), do: nil

  defp filename_slug(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.replace_suffix(".tar.gz", "")
    |> String.replace_suffix(".tgz", "")
    |> Skill.slugify()
  end
end
