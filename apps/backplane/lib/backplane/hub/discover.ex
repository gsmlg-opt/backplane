defmodule Backplane.Hub.Discover do
  @moduledoc """
  Cross-cutting discovery across tools and skills.
  """

  require Logger

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Utils

  @default_limit 5
  @all_scopes ["tools", "skills"]

  @doc """
  Search across all hub engines.

  Options:
    - :scope - list of scopes to search (default: all)
    - :limit - max results per scope (default: 5)
  """
  @spec search(String.t(), keyword()) :: {:ok, map()}
  def search(query, opts \\ [])
  def search("", _opts), do: {:ok, %{tools: [], skills: [], total: 0}}
  def search(nil, _opts), do: {:ok, %{tools: [], skills: [], total: 0}}

  def search(query, opts) do
    scopes = Keyword.get(opts, :scope, @all_scopes)
    limit = Keyword.get(opts, :limit, @default_limit)
    query = sanitize_query(query)

    # Run scope searches concurrently — each hits independent data sources
    scope_fns = %{
      "tools" => fn -> search_tools(query, limit) end,
      "skills" => fn -> search_skills(query, limit) end
    }

    tasks =
      scopes
      |> Enum.filter(&Map.has_key?(scope_fns, &1))
      |> Enum.map(fn scope -> {scope, Task.async(scope_fns[scope])} end)

    task_map = Map.new(tasks, fn {scope, task} -> {task.ref, scope} end)

    results =
      tasks
      |> Enum.map(fn {_scope, task} -> task end)
      |> Task.yield_many(10_000)
      |> Enum.reduce(%{}, fn {task, result}, acc ->
        scope = Map.fetch!(task_map, task.ref)

        case result do
          {:ok, value} ->
            Map.put(acc, scope, value)

          {:exit, reason} ->
            Logger.warning("Hub discover scope #{scope} crashed: #{inspect(reason)}")
            Map.put(acc, scope, [])

          nil ->
            Task.shutdown(task, :brutal_kill)
            Logger.warning("Hub discover scope #{scope} timed out")
            Map.put(acc, scope, [])
        end
      end)

    tools = Map.get(results, "tools", [])
    skills = Map.get(results, "skills", [])

    {:ok,
     %{
       tools: tools,
       skills: skills,
       total: length(tools) + length(skills)
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

  @max_query_length 500
  defp sanitize_query(query) do
    query |> String.replace(<<0>>, "") |> String.slice(0, @max_query_length)
  end

  defp format_origin(origin), do: Utils.format_origin(origin)
end
