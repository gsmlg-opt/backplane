defmodule Backplane.Skills do
  @moduledoc """
  Public context for archive-backed skills.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Archive
  alias Backplane.Skills.Blob
  alias Backplane.Skills.Ingest
  alias Backplane.Skills.Registry
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Search

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
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
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
    case Repo.delete(skill) do
      {:ok, deleted} ->
        Registry.refresh()
        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete(id) when is_binary(id) do
    with {:ok, skill} <- get(id) do
      delete(skill)
    end
  end

  @doc "Ingest an archive-backed skill."
  @spec ingest_archive(term(), map() | keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def ingest_archive(archive, opts), do: Ingest.ingest(archive, opts)

  @doc "Stream a skill archive."
  @spec archive_stream(String.t() | Skill.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def archive_stream(%Skill{archive_ref: archive_ref}) when is_binary(archive_ref) do
    Blob.get(archive_ref)
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

  @doc "Export a skill archive."
  @spec export(String.t()) :: {:error, :not_implemented}
  def export(_skill_id), do: {:error, :not_implemented}

  @doc "Import a skill archive."
  @spec import(term(), map()) :: {:error, :not_implemented}
  def import(_archive, _opts), do: {:error, :not_implemented}

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
end
