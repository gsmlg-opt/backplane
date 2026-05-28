defmodule Backplane.Skills.SkillSources do
  @moduledoc """
  Context for managing upstream skill sync sources.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.SkillSource

  require Logger

  @doc "List all configured sources."
  @spec list() :: [SkillSource.t()]
  def list do
    SkillSource
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "Fetch a source by ID."
  @spec get(String.t()) :: {:ok, SkillSource.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(SkillSource, id) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  @doc "Create a new source."
  @spec create(map()) :: {:ok, SkillSource.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %SkillSource{}
    |> SkillSource.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a source."
  @spec update(SkillSource.t(), map()) :: {:ok, SkillSource.t()} | {:error, Ecto.Changeset.t()}
  def update(%SkillSource{} = source, attrs) do
    source
    |> SkillSource.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a source."
  @spec delete(SkillSource.t()) :: {:ok, SkillSource.t()} | {:error, Ecto.Changeset.t()}
  def delete(%SkillSource{} = source) do
    Repo.delete(source)
  end

  @doc "Count total sources."
  @spec count() :: non_neg_integer()
  def count do
    Repo.aggregate(SkillSource, :count, :id)
  end

  @doc """
  Fetch the remote skill list from an upstream source.
  Returns a list of skill entry maps that are available for import.
  """
  @spec list_remote_skills(SkillSource.t()) :: {:ok, [map()]} | {:error, term()}
  def list_remote_skills(%SkillSource{source_type: "github"} = source) do
    Backplane.Skills.Sources.GitHub.list_skills(source)
  end

  def list_remote_skills(%SkillSource{source_type: type}) do
    {:error, {:unsupported_source_type, type}}
  end

  @doc """
  Sync selected skills from a remote source into the local database.
  `skill_entries` is a list of skill entry maps returned by `list_remote_skills/1`.
  If `extra_tags` is provided, they are merged into each skill's tags.
  """
  @spec sync_skills(SkillSource.t(), [map()], [String.t()]) ::
          {:ok, %{synced: non_neg_integer(), errors: [term()]}} | {:error, term()}
  def sync_skills(%SkillSource{} = source, skill_entries, extra_tags \\ [])
      when is_list(skill_entries) do
    results =
      Enum.map(skill_entries, fn entry ->
        entry =
          if extra_tags != [] do
            existing = entry[:tags] || []
            merged = Enum.uniq(existing ++ extra_tags)
            put_entry(entry, :tags, merged)
          else
            entry
          end

        upsert_synced_skill(source, entry)
      end)

    synced = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1)) |> Enum.map(fn {:error, e} -> e end)

    # Update source sync status
    now = DateTime.utc_now()
    status = if errors == [], do: "success", else: "partial"

    __MODULE__.update(source, %{
      last_synced_at: now,
      last_sync_status: status,
      last_sync_error: if(errors == [], do: nil, else: inspect(Enum.take(errors, 3))),
      sync_metadata:
        Map.merge(source.sync_metadata, %{
          "last_synced_count" => synced,
          "last_error_count" => length(errors)
        })
    })

    # Refresh registry
    Backplane.Skills.Registry.refresh()

    {:ok, %{synced: synced, errors: errors}}
  end

  @doc """
  One-click sync: fetches remote skills, filters to selected_skills,
  merges sync_tags, and upserts into the local database.
  """
  @spec sync_from_source(SkillSource.t()) ::
          {:ok, %{synced: non_neg_integer(), errors: [term()]}} | {:error, term()}
  def sync_from_source(%SkillSource{} = source) do
    case list_remote_skills(source) do
      {:ok, remote_skills} ->
        selected = source.selected_skills || []

        entries =
          if selected == [] do
            # If no specific selection, sync all
            remote_skills
          else
            Enum.filter(remote_skills, fn skill ->
              skill[:slug] in selected
            end)
          end

        sync_skills(source, entries, source.sync_tags || [])

      {:error, reason} ->
        # Record the failure on the source
        __MODULE__.update(source, %{
          last_synced_at: DateTime.utc_now(),
          last_sync_status: "failed",
          last_sync_error: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp put_entry(entry, key, value) when is_map(entry), do: Map.put(entry, key, value)
  defp put_entry(entry, key, value) when is_list(entry), do: Keyword.put(entry, key, value)

  defp upsert_synced_skill(source, entry) do
    alias Backplane.Skills.Skill

    hash =
      :crypto.hash(:sha256, entry[:content] || "")
      |> Base.encode16(case: :lower)

    slug = entry[:slug] || derive_slug(entry[:name])
    id = "github/#{slug}"

    attrs = %{
      id: id,
      slug: slug,
      name: entry[:name],
      description: entry[:description] || "",
      tags: entry[:tags] || [],
      category: entry[:category],
      content: entry[:content],
      content_hash: hash,
      enabled: true,
      version: entry[:version],
      license: entry[:license],
      homepage: entry[:homepage],
      author: entry[:author],
      meta: entry[:meta] || %{},
      source_kind: "github",
      source_uri: source.url,
      source_rev: source.branch
    }

    case Repo.get_by(Skill, slug: slug) do
      nil ->
        %Skill{}
        |> Skill.changeset(attrs)
        |> Repo.insert()

      %Skill{} = skill ->
        skill
        |> Skill.changeset(attrs)
        |> Repo.update()
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp derive_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "skill-#{:rand.uniform(99999)}"
      slug -> slug
    end
  end

  defp derive_slug(_), do: "skill-#{:rand.uniform(99999)}"
end
