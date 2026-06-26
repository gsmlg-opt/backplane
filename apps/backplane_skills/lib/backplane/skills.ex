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

  @doc "Update an existing skill."
  @spec update(Skill.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def update(%Skill{} = skill, attrs) do
    metadata = %{action: "update", skill_id: skill.id, slug: skill.slug}

    :telemetry.span([:backplane, :skills, :access], metadata, fn ->
      result =
        skill
        |> Skill.update_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Registry.refresh()
            {:ok, updated}

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

  # ── Stats & Helpers ───────────────────────────────────────────────────────

  @doc "List all skills (including disabled), with optional filters."
  @spec list_all(keyword()) :: [Skill.t()]
  def list_all(opts \\ []) do
    source_kind = Keyword.get(opts, :source_kind)
    category = Keyword.get(opts, :category)

    Skill
    |> maybe_source_kind_filter(source_kind)
    |> maybe_category_filter(category)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "Paginated skill list with filters."
  @spec paginated_list(keyword()) :: %{skills: [Skill.t()], total: non_neg_integer()}
  def paginated_list(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 25)
    q = Keyword.get(opts, :q, "")
    source_kind = Keyword.get(opts, :source_kind)
    category = Keyword.get(opts, :category)
    tag = Keyword.get(opts, :tag)
    include_disabled? = Keyword.get(opts, :include_disabled, false)

    base =
      Skill
      |> maybe_enabled_filter(include_disabled?)
      |> maybe_source_kind_filter(source_kind)
      |> maybe_category_filter(category)
      |> maybe_tag_filter(tag)
      |> maybe_text_filter(q)

    total = Repo.aggregate(base, :count, :id)

    skills =
      base
      |> order_by([s], asc: s.name)
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()

    %{skills: skills, total: total}
  end

  @doc "Total skill count."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    include_disabled? = Keyword.get(opts, :include_disabled, false)

    Skill
    |> maybe_enabled_filter(include_disabled?)
    |> Repo.aggregate(:count, :id)
  end

  @doc "Count skills grouped by source_kind."
  @spec count_by_source_kind() :: %{String.t() => non_neg_integer()}
  def count_by_source_kind do
    Skill
    |> group_by([s], s.source_kind)
    |> select([s], {s.source_kind, count(s.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc "Count skills grouped by category."
  @spec count_by_category() :: %{String.t() => non_neg_integer()}
  def count_by_category do
    Skill
    |> where([s], not is_nil(s.category) and s.category != "")
    |> group_by([s], s.category)
    |> select([s], {s.category, count(s.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc "List all unique tags across skills."
  @spec list_tags() :: [%{tag: String.t(), count: non_neg_integer()}]
  def list_tags do
    Skill
    |> select([s], s.tags)
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc "List all unique categories across skills."
  @spec list_categories() :: [%{category: String.t(), count: non_neg_integer()}]
  def list_categories do
    Skill
    |> where([s], not is_nil(s.category) and s.category != "")
    |> group_by([s], s.category)
    |> select([s], %{category: s.category, count: count(s.id)})
    |> order_by([s], desc: count(s.id))
    |> Repo.all()
  end

  @doc "Bulk update tags for a list of skill IDs."
  @spec bulk_update_tags([String.t()], [String.t()]) :: {non_neg_integer(), nil}
  def bulk_update_tags(skill_ids, tags) when is_list(skill_ids) and is_list(tags) do
    from(s in Skill, where: s.id in ^skill_ids)
    |> Repo.update_all(set: [tags: tags, updated_at: DateTime.utc_now()])
  end

  @doc "Bulk update category for a list of skill IDs."
  @spec bulk_update_category([String.t()], String.t() | nil) :: {non_neg_integer(), nil}
  def bulk_update_category(skill_ids, category) when is_list(skill_ids) do
    from(s in Skill, where: s.id in ^skill_ids)
    |> Repo.update_all(set: [category: category, updated_at: DateTime.utc_now()])
  end

  @doc "Rename a tag across all skills that have it."
  @spec rename_tag(String.t(), String.t()) :: :ok
  def rename_tag(old_tag, new_tag) do
    skills =
      Skill
      |> where([s], ^old_tag in s.tags)
      |> Repo.all()

    Enum.each(skills, fn skill ->
      new_tags =
        skill.tags
        |> Enum.map(fn t -> if t == old_tag, do: new_tag, else: t end)
        |> Enum.uniq()

      skill
      |> Skill.update_changeset(%{tags: new_tags})
      |> Repo.update()
    end)

    :ok
  end

  @doc "Remove a tag from all skills."
  @spec delete_tag(String.t()) :: :ok
  def delete_tag(tag) do
    skills =
      Skill
      |> where([s], ^tag in s.tags)
      |> Repo.all()

    Enum.each(skills, fn skill ->
      new_tags = Enum.reject(skill.tags, &(&1 == tag))

      skill
      |> Skill.update_changeset(%{tags: new_tags})
      |> Repo.update()
    end)

    :ok
  end

  @doc "Rename a category across all skills."
  @spec rename_category(String.t(), String.t()) :: {non_neg_integer(), nil}
  def rename_category(old_category, new_category) do
    from(s in Skill, where: s.category == ^old_category)
    |> Repo.update_all(set: [category: new_category, updated_at: DateTime.utc_now()])
  end

  @doc "Delete a category (set to nil) across all skills."
  @spec delete_category(String.t()) :: {non_neg_integer(), nil}
  def delete_category(category) do
    from(s in Skill, where: s.category == ^category)
    |> Repo.update_all(set: [category: nil, updated_at: DateTime.utc_now()])
  end

  @doc "List recent skills by updated_at."
  @spec recent(non_neg_integer()) :: [Skill.t()]
  def recent(limit \\ 5) do
    Skill
    |> order_by([s], desc: s.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_source_kind_filter(query, nil), do: query
  defp maybe_source_kind_filter(query, ""), do: query
  defp maybe_source_kind_filter(query, kind), do: where(query, [s], s.source_kind == ^kind)

  defp maybe_category_filter(query, nil), do: query
  defp maybe_category_filter(query, ""), do: query
  defp maybe_category_filter(query, cat), do: where(query, [s], s.category == ^cat)

  defp maybe_tag_filter(query, nil), do: query
  defp maybe_tag_filter(query, ""), do: query
  defp maybe_tag_filter(query, tag), do: where(query, [s], ^tag in s.tags)

  defp maybe_text_filter(query, nil), do: query
  defp maybe_text_filter(query, ""), do: query

  defp maybe_text_filter(query, q) do
    sanitized = q |> String.replace(<<0>>, "") |> String.slice(0, 500)
    where(query, [s], fragment("search_vector @@ plainto_tsquery('english', ?)", ^sanitized))
  end

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
