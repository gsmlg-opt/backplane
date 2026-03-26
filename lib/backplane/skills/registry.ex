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
  def list(opts \\ []) do
    source_filter = Keyword.get(opts, :source)
    tags_filter = Keyword.get(opts, :tags, [])

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> entry end)
    |> maybe_filter_source(source_filter)
    |> maybe_filter_tags(tags_filter)
  end

  @doc "Search skills by keyword in name and description."
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    query_down = String.downcase(query)

    for {_id, entry} <- :ets.tab2list(@table),
        String.contains?(String.downcase(entry.name), query_down) ||
          String.contains?(String.downcase(entry.description), query_down) do
      entry
    end
    |> Enum.take(limit)
  end

  @doc "Fetch a single skill by ID."
  def fetch(skill_id) do
    case :ets.lookup(@table, skill_id) do
      [{^skill_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Return the total number of skills in the registry."
  def count do
    :ets.info(@table, :size)
  end

  @doc "Reload the ETS table from the database."
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

    # Atomic: delete + bulk insert minimizes the window where the table is empty
    :ets.delete_all_objects(@table)
    :ets.insert(@table, rows)

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
