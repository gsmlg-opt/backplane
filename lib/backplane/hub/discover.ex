defmodule Backplane.Hub.Discover do
  @moduledoc """
  Cross-cutting discovery across tools, skills, docs, and repos.
  """

  @default_limit 5
  @all_scopes ["tools", "skills", "docs", "repos"]

  @doc """
  Search across all hub engines.

  Options:
    - :scope - list of scopes to search (default: all)
    - :limit - max results per scope (default: 5)
  """
  def search(query, opts \\ []) do
    scopes = Keyword.get(opts, :scope, @all_scopes)
    limit = Keyword.get(opts, :limit, @default_limit)

    result = %{
      tools: if("tools" in scopes, do: search_tools(query, limit), else: []),
      skills: if("skills" in scopes, do: search_skills(query, limit), else: []),
      docs: if("docs" in scopes, do: search_docs(query, limit), else: []),
      repos: if("repos" in scopes, do: search_repos(query, limit), else: [])
    }

    {:ok, result}
  end

  defp search_tools(query, limit) do
    Backplane.Registry.ToolRegistry.search(query, limit: limit)
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        origin: format_origin(tool.origin)
      }
    end)
  end

  defp search_skills(query, limit) do
    Backplane.Skills.Registry.search(query, limit: limit)
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
    import Ecto.Query

    try do
      Backplane.Docs.DocChunk
      |> where([c], fragment("search_vector @@ plainto_tsquery('english', ?)", ^query))
      |> order_by([c],
        desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^query)
      )
      |> limit(^limit)
      |> Backplane.Repo.all()
      |> Enum.map(fn chunk ->
        %{
          project: chunk.project_id,
          module: chunk.module,
          function: chunk.function,
          snippet: String.slice(chunk.content, 0, 200)
        }
      end)
    rescue
      _ -> []
    end
  end

  defp search_repos(_query, _limit) do
    # Repos come from config, not a searchable DB
    # Return configured projects as available repos
    import Ecto.Query

    try do
      Backplane.Docs.Project
      |> limit(10)
      |> Backplane.Repo.all()
      |> Enum.map(fn p ->
        %{repo: p.repo, description: p.description}
      end)
    rescue
      _ -> []
    end
  end

  defp format_origin(origin), do: Backplane.Utils.format_origin(origin)
end
