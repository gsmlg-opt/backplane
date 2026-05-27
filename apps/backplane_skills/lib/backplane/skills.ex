defmodule Backplane.Skills do
  @moduledoc """
  Public context for archive-backed skills.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Archive
  alias Backplane.Skills.Blob
  alias Backplane.Skills.Export
  alias Backplane.Skills.Ingest
  alias Backplane.Skills.Registry
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Search

  require Logger

  @doc "List enabled skills."
  @spec list(keyword()) :: [Skill.t()]
  def list(opts \\ []) do
    include_disabled? = Keyword.get(opts, :include_disabled, false)

    Skill
    |> maybe_enabled_filter(include_disabled?)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "Search enabled skills."
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    Search.query(query, opts)
  end

  @doc "Fetch a skill by ID."
  @spec get(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    metadata = %{action: "get", skill_id: id}

    :telemetry.span([:backplane, :skills, :access], metadata, fn ->
      result =
        case Repo.get(Skill, id) do
          nil -> {:error, :not_found}
          skill -> {:ok, skill}
        end

      status =
        case result do
          {:ok, skill} -> %{status: :ok, slug: skill.slug}
          {:error, :not_found} -> %{status: :not_found}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  @doc "Fetch a skill by slug."
  @spec get_by_slug(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Skill, slug: slug) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  @doc "Delete a skill by ID or struct."
  @spec delete(String.t() | Skill.t()) ::
          {:ok, Skill.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete(%Skill{} = skill) do
    metadata = %{action: "delete", skill_id: skill.id, slug: skill.slug}

    :telemetry.span([:backplane, :skills, :access], metadata, fn ->
      result =
        case Repo.delete(skill) do
          {:ok, deleted} ->
            cleanup_archive_blob(deleted)
            Registry.refresh()
            {:ok, deleted}

          {:error, changeset} ->
            {:error, changeset}
        end

      status =
        case result do
          {:ok, _} -> %{status: :ok}
          {:error, reason} -> %{status: :error, error: inspect(reason)}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  def delete(id) when is_binary(id) do
    with {:ok, skill} <- get(id) do
      delete(skill)
    end
  end

  @doc "Ingest an archive-backed skill."
  @spec ingest_archive(term(), map() | keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def ingest_archive(archive, opts) do
    metadata = %{action: "ingest"}

    :telemetry.span([:backplane, :skills, :access], metadata, fn ->
      result = Ingest.ingest(archive, opts)

      status =
        case result do
          {:ok, skill} -> %{status: :ok, skill_id: skill.id, slug: skill.slug}
          {:error, reason} -> %{status: :error, error: inspect(reason)}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  @doc "Stream a skill archive."
  @spec archive_stream(String.t() | Skill.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def archive_stream(%Skill{archive_ref: archive_ref} = skill) when is_binary(archive_ref) do
    metadata = %{action: "archive_stream", skill_id: skill.id, slug: skill.slug}

    :telemetry.span([:backplane, :skills, :access], metadata, fn ->
      result = Blob.get(archive_ref)

      status =
        case result do
          {:ok, _} -> %{status: :ok}
          {:error, reason} -> %{status: :error, error: inspect(reason)}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  def archive_stream(%Skill{}), do: {:error, :not_found}

  def archive_stream(skill_id_or_slug) when is_binary(skill_id_or_slug) do
    with {:ok, skill} <- get_by_slug_or_id(skill_id_or_slug) do
      archive_stream(skill)
    end
  end

  @doc "List files contained in a stored skill archive."
  @spec archive_files(String.t() | Skill.t()) :: {:ok, [String.t()]} | {:error, term()}
  def archive_files(skill_or_id) do
    with {:ok, stream} <- archive_stream(skill_or_id),
         {:ok, path} <- write_stream_to_temp(stream) do
      try do
        with {:ok, inspected} <- Archive.inspect(path) do
          {:ok, inspected.files}
        end
      after
        File.rm(path)
      end
    end
  end

  @doc """
  Export archive-backed skills into a collection archive.

  Options:

    * `:path` - destination tar.gz path. Defaults to a temporary file.
  """
  @spec export(keyword() | map() | String.t()) ::
          {:ok, Export.export_result()} | {:error, term()}
  def export(opts \\ [])
  def export(opts) when is_list(opts) or is_map(opts), do: Export.export(opts)
  def export(legacy_skill_id) when is_binary(legacy_skill_id), do: {:error, :not_implemented}

  @doc """
  Import archive-backed skills from a collection archive path or upload.

  Every `archives/<slug>.tar.gz` entry is passed to archive ingest unchanged.
  """
  @spec import(String.t() | %{path: String.t()}, keyword() | map()) ::
          {:ok, Export.import_result()} | {:error, term()}
  def import(collection, opts \\ [])

  def import(path, opts) when is_binary(path) do
    if File.regular?(path) do
      Export.import(path, opts)
    else
      {:error, :not_implemented}
    end
  end

  def import(collection, opts), do: Export.import(collection, opts)

  defp maybe_enabled_filter(query, true), do: query
  defp maybe_enabled_filter(query, false), do: where(query, [s], s.enabled == true)

  defp get_by_slug_or_id(value) do
    case get_by_slug(value) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> get(value)
    end
  end

  defp write_stream_to_temp(stream) do
    path =
      Path.join(
        System.tmp_dir!(),
        "backplane-skill-archive-#{System.unique_integer([:positive])}.tar.gz"
      )

    case File.open(path, [:write, :binary], fn io ->
           Enum.each(stream, &IO.binwrite(io, &1))
         end) do
      {:ok, :ok} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_archive_blob(%Skill{source_kind: "archive", archive_ref: archive_ref})
       when is_binary(archive_ref) do
    unless Repo.exists?(from(s in Skill, where: s.archive_ref == ^archive_ref)) do
      case Blob.delete(archive_ref) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to cleanup unreferenced skill archive blob #{archive_ref}: #{inspect(reason)}"
          )
      end
    end
  end

  defp cleanup_archive_blob(_skill), do: :ok
end
