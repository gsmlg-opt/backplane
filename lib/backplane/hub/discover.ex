defmodule Backplane.Hub.Discover do
  @moduledoc """
  Cross-cutting discovery across tools, skills, docs, and repos.
  """

  require Logger

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Utils

  import Ecto.Query

  @default_limit 5
  @all_scopes ["tools", "skills", "docs", "repos"]

  @doc """
  Search across all hub engines.

  Options:
    - :scope - list of scopes to search (default: all)
    - :limit - max results per scope (default: 5)
  """
  @spec search(String.t(), keyword()) :: {:ok, map()}
  def search(query, opts \\ [])
  def search("", _opts), do: {:ok, %{tools: [], skills: [], docs: [], repos: []}}
  def search(nil, _opts), do: {:ok, %{tools: [], skills: [], docs: [], repos: []}}

  def search(query, opts) do
    scopes = Keyword.get(opts, :scope, @all_scopes)
    limit = Keyword.get(opts, :limit, @default_limit)
    query = sanitize_query(query)

    # Run scope searches concurrently — each hits independent data sources
    scope_fns = %{
      "tools" => fn -> search_tools(query, limit) end,
      "skills" => fn -> search_skills(query, limit) end,
      "docs" => fn -> search_docs(query, limit) end,
      "repos" => fn -> search_repos(query, limit) end
    }

    results =
      scopes
      |> Enum.filter(&Map.has_key?(scope_fns, &1))
      |> Enum.map(fn scope -> {scope, Task.async(scope_fns[scope])} end)
      |> Enum.map(fn {scope, task} -> {scope, Task.await(task, 10_000)} end)
      |> Map.new()

    {:ok,
     %{
       tools: Map.get(results, "tools", []),
       skills: Map.get(results, "skills", []),
       docs: Map.get(results, "docs", []),
       repos: Map.get(results, "repos", [])
     }}
  end

  defp search_tools(query, limit) do
    ToolRegistry.search(query, limit: limit)
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        origin: format_origin(tool.origin)
      }
    end)
  end

  defp search_skills(query, limit) do
    SkillsRegistry.search(query, limit: limit)
    |> Enum.map(fn skill ->
      %{
        id: skill.id,
        name: skill.name,
        description: skill.description,
        tags: skill.tags
      }
    end)
  end

  defp search_docs(query, limit) do
    DocChunk
    |> where([c], fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^query))
    |> order_by([c],
      desc: fragment("ts_rank(search_vector, websearch_to_tsquery('english', ?))", ^query)
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn chunk ->
      %{
        project: chunk.project_id,
        module: chunk.module,
        function: chunk.function,
        snippet: String.slice(chunk.content, 0, 200)
      }
    end)
  rescue
    e ->
      Logger.warning("Failed to search docs: #{Exception.message(e)}")
      []
  end

  defp search_repos(query, limit) do
    downcased = query |> String.downcase() |> Utils.escape_like()
    pattern = "%#{downcased}%"

    Project
    |> where(
      [p],
      ilike(p.id, ^pattern) or ilike(p.repo, ^pattern) or ilike(p.description, ^pattern)
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn p ->
      %{id: p.id, repo: p.repo, description: p.description}
    end)
  rescue
    e ->
      Logger.warning("Failed to search repos: #{Exception.message(e)}")
      []
  end

  defp sanitize_query(query), do: String.replace(query, <<0>>, "")

  defp format_origin(origin), do: Utils.format_origin(origin)
end
