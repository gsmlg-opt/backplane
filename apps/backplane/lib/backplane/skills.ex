defmodule Backplane.Skills do
  @moduledoc """
  Public context for Skills Hub operations.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Ingest, Search, Skill}
  alias Backplane.Skills.Blob.LocalFS
  alias Backplane.Skills.Sources.Database

  @doc "List enabled skills with metadata."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    query = Keyword.get(opts, :query) || Keyword.get(opts, :q)
    Search.query(query, opts)
  end

  @doc "Search enabled skills."
  @spec search(String.t() | nil, keyword()) :: [map()]
  def search(query, opts \\ []), do: Search.query(query, opts)

  @doc "Fetch a skill by id or slug."
  @spec get(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get(id_or_slug) when is_binary(id_or_slug) do
    case Repo.get(Skill, id_or_slug) do
      nil -> get_by_slug(id_or_slug)
      %Skill{} = skill -> {:ok, skill}
    end
  end

  @doc "Fetch a skill by slug."
  @spec get_by_slug(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Skill, slug: slug) do
      nil -> {:error, :not_found}
      %Skill{} = skill -> {:ok, skill}
    end
  end

  @doc "Delete a skill by id or slug."
  @spec delete(String.t()) :: {:ok, Skill.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete(id_or_slug) when is_binary(id_or_slug) do
    with {:ok, skill} <- get(id_or_slug),
         {:ok, deleted} <- Repo.delete(skill) do
      if deleted.archive_ref, do: LocalFS.delete(deleted.content_hash)
      Backplane.Skills.Registry.refresh()
      {:ok, deleted}
    end
  end

  @doc "Create a legacy database-backed string skill."
  @spec create(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: Database.create(attrs)

  @doc "Update a legacy database-backed string skill."
  @spec update(String.t(), map()) :: {:ok, Skill.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update(id_or_slug, attrs), do: Database.update(id_or_slug, attrs)

  @doc false
  def ingest_archive(source, opts \\ []), do: Ingest.ingest(source, opts)

  @doc false
  def archive_stream(id_or_slug) do
    with {:ok, skill} <- get(id_or_slug),
         {:ok, stream} <- LocalFS.get(skill.content_hash) do
      {:ok, skill, stream}
    end
  end

  @doc false
  def export(_opts \\ []), do: {:error, :not_implemented}

  @doc false
  def import(_source, _opts \\ []), do: {:error, :not_implemented}

  @doc "Return the base query used by internals that need full skill rows."
  @spec enabled_query() :: Ecto.Query.t()
  def enabled_query do
    from(s in Skill, where: s.enabled == true)
  end
end
