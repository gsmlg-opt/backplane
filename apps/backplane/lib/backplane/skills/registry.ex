defmodule Backplane.Skills.Registry do
  @moduledoc """
  ETS-backed skills registry. Mirrors the skills table for fast reads.
  Rebuilt on boot from PostgreSQL.
  """

  use GenServer

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @table :backplane_skills

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    refresh()
    {:ok, %{}}
  end

  @doc "List all skills, optionally filtering by source and/or tags."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    source_filter = Keyword.get(opts, :source)
    tags_filter = Keyword.get(opts, :tags, [])

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> entry end)
    |> maybe_filter_source(source_filter)
    |> maybe_filter_tags(tags_filter)
  end

  @doc "Search skills by keyword in name, description, and tags. Results are relevance-sorted."
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> {entry, score_skill(entry, terms)} end)
    |> Enum.filter(fn {_entry, score} -> score > 0 end)
    |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {entry, _score} -> entry end)
  end

  defp score_skill(entry, terms) do
    name_down = String.downcase(entry.name)
    desc_down = String.downcase(entry.description || "")
    tags_down = Enum.map(entry.tags || [], &String.downcase/1)

    Enum.reduce(terms, 0, fn term, acc ->
      name_score = if String.contains?(name_down, term), do: 3, else: 0
      tag_score = if Enum.any?(tags_down, &String.contains?(&1, term)), do: 2, else: 0
      desc_score = if String.contains?(desc_down, term), do: 1, else: 0
      acc + name_score + tag_score + desc_score
    end)
  end

  @doc "Fetch a single skill by ID."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch(skill_id) do
    case :ets.lookup(@table, skill_id) do
      [{^skill_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Return the total number of skills in the registry."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc "Reload the ETS table from the database."
  @spec refresh() :: :ok
  def refresh do
    skills = Repo.all(from(s in Skill, where: s.enabled == true))

    rows =
      Enum.map(skills, fn skill ->
        {skill.id,
         %{
           id: skill.id,
           name: skill.name,
           description: skill.description,
           tags: skill.tags,
           tools: skill.tools,
           model: skill.model,
           version: skill.version,
           content: skill.content,
           content_hash: skill.content_hash,
           source: skill.source
         }}
      end)

    # Insert first, then remove stale keys — avoids an empty-table window
    # where concurrent readers would see zero skills
    new_ids = MapSet.new(rows, fn {id, _} -> id end)
    :ets.insert(@table, rows)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {id, _} ->
      unless MapSet.member?(new_ids, id), do: :ets.delete(@table, id)
    end)

    # Notify connected MCP clients that prompts (skills) have changed
    Backplane.Notifications.prompts_changed()

    :ok
  end

  defp maybe_filter_source(entries, nil), do: entries

  defp maybe_filter_source(entries, source) do
    Enum.filter(entries, fn entry ->
      entry.source == source || String.starts_with?(entry.source, source <> ":")
    end)
  end

  defp maybe_filter_tags(entries, []), do: entries

  defp maybe_filter_tags(entries, tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(entries, fn entry ->
      entry_tags = Map.get(entry, :tags, []) |> MapSet.new()
      MapSet.subset?(tag_set, entry_tags)
    end)
  end
end
