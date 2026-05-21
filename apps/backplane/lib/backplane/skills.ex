defmodule Backplane.Skills do
  @moduledoc """
  Public context for archive-backed skills.
  """

  import Ecto.Query

  alias Backplane.Repo
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
  @spec archive_stream(String.t()) :: {:error, :not_implemented}
  def archive_stream(_skill_id), do: {:error, :not_implemented}

  @doc "Export a skill archive."
  @spec export(String.t()) :: {:error, :not_implemented}
  def export(_skill_id), do: {:error, :not_implemented}

  @doc "Import a skill archive."
  @spec import(term(), map()) :: {:error, :not_implemented}
  def import(_archive, _opts), do: {:error, :not_implemented}

  defp maybe_enabled_filter(query, true), do: query
  defp maybe_enabled_filter(query, false), do: where(query, [s], s.enabled == true)
end
