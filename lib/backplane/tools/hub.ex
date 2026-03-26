defmodule Backplane.Tools.Hub do
  @moduledoc """
  Native MCP tools for hub-level discovery and introspection.
  """

  @behaviour Backplane.Tools.ToolModule

  require Logger

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Hub.Discover
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.{Registry, Skill}

  import Ecto.Query

  def tools do
    [
      %{
        name: "hub::discover",
        description: "Unified search across tools, skills, docs, and repos",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search keywords"},
            "scope" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter to specific scopes: tools, skills, docs, repos"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Max results per scope (default 5)"
            }
          },
          "required" => ["query"]
        },
        module: __MODULE__,
        handler: :discover
      },
      %{
        name: "hub::inspect",
        description: "Introspect a tool's full schema, origin, and health",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "tool_name" => %{"type" => "string", "description" => "Full namespaced tool name"}
          },
          "required" => ["tool_name"]
        },
        module: __MODULE__,
        handler: :inspect
      },
      %{
        name: "hub::status",
        description: "Health and status overview of the entire hub",
        input_schema: %{
          "type" => "object",
          "properties" => %{}
        },
        module: __MODULE__,
        handler: :status
      }
    ]
  end

  def call(%{"_handler" => "discover"} = args) do
    opts =
      []
      |> maybe_add(:scope, args["scope"])
      |> maybe_add(:limit, args["limit"])

    Discover.search(args["query"], opts)
  end

  def call(%{"_handler" => "inspect"} = args) do
    tool_name = args["tool_name"]

    case find_tool(tool_name) do
      nil ->
        {:error, "Unknown tool: #{tool_name}"}

      tool ->
        {:ok,
         %{
           name: tool.name,
           description: tool.description,
           input_schema: tool.input_schema,
           origin: format_origin(tool.origin),
           upstream_name: if(match?({:upstream, _}, tool.origin), do: elem(tool.origin, 1)),
           upstream_healthy: if(tool.upstream_pid, do: Process.alive?(tool.upstream_pid))
         }}
    end
  end

  def call(%{"_handler" => "status"}) do
    upstreams = get_upstream_status()
    skill_sources = get_skill_sources()
    doc_projects = get_doc_projects()

    {:ok,
     %{
       upstreams: upstreams,
       skill_sources: skill_sources,
       doc_projects: doc_projects,
       total_tools: ToolRegistry.count(),
       total_skills: Registry.count()
     }}
  end

  def call(_args), do: {:error, "Unknown hub tool handler"}

  defp find_tool(name), do: ToolRegistry.lookup(name)

  defp get_upstream_status do
    Pool.list_upstreams()
    |> Enum.map(fn u ->
      %{name: u.name, status: u.status, tool_count: u.tool_count}
    end)
  rescue
    e ->
      Logger.warning("Failed to get upstream status: #{Exception.message(e)}")
      []
  end

  defp get_skill_sources do
    Skill
    |> where([s], s.enabled == true)
    |> group_by([s], s.source)
    |> select([s], {s.source, count(s.id)})
    |> Repo.all()
    |> Enum.map(fn {source, count} ->
      %{name: source, skill_count: count}
    end)
  rescue
    e ->
      Logger.warning("Failed to get skill sources: #{Exception.message(e)}")
      []
  end

  defp get_doc_projects do
    chunk_counts =
      DocChunk
      |> group_by([c], c.project_id)
      |> select([c], {c.project_id, count(c.id)})
      |> Repo.all()
      |> Map.new()

    Project
    |> Repo.all()
    |> Enum.map(fn p ->
      %{id: p.id, chunk_count: Map.get(chunk_counts, p.id, 0), last_indexed: p.last_indexed_at}
    end)
  rescue
    e ->
      Logger.warning("Failed to get doc projects: #{Exception.message(e)}")
      []
  end

  defp format_origin(origin), do: Backplane.Utils.format_origin(origin)

  defp maybe_add(opts, key, value), do: Backplane.Utils.maybe_put(opts, key, value)
end
