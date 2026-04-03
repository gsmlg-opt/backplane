defmodule Backplane.Tools.Hub do
  @moduledoc """
  Native MCP tools for hub-level discovery and introspection.
  """

  @behaviour Backplane.Tools.ToolModule

  require Logger

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Git.RateLimitCache
  alias Backplane.Hub.{Discover, Inspect}
  alias Backplane.Notifications
  alias Backplane.Proxy.{Pool, Upstream}
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.{Registry, Skill}
  alias Backplane.Utils

  import Ecto.Query

  @impl true
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
      },
      %{
        name: "hub::refresh",
        description: "Trigger tool rediscovery on one or all upstream MCP servers",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "upstream" => %{
              "type" => "string",
              "description" => "Name of a specific upstream to refresh (omit for all)"
            }
          }
        },
        module: __MODULE__,
        handler: :refresh
      }
    ]
  end

  @impl true
  @spec call(map()) :: {:ok, term()} | {:error, term()}
  def call(%{"_handler" => "discover"} = args) do
    opts =
      []
      |> maybe_add(:scope, args["scope"])
      |> maybe_add(:limit, args["limit"])

    Discover.search(args["query"], opts)
  end

  def call(%{"_handler" => "inspect"} = args) do
    Inspect.introspect(args["tool_name"])
  end

  def call(%{"_handler" => "status"}) do
    upstreams = get_upstream_status()
    skill_sources = get_skill_sources()
    doc_projects = get_doc_projects()
    git_providers = get_git_providers()

    {:ok,
     %{
       upstreams: upstreams,
       skill_sources: skill_sources,
       doc_projects: doc_projects,
       git_providers: git_providers,
       total_tools: ToolRegistry.count(),
       total_skills: Registry.count(),
       sse_subscribers: Notifications.subscriber_count(),
       version: Backplane.version()
     }}
  end

  def call(%{"_handler" => "refresh"} = args) do
    refresh_upstreams(args["upstream"])
  end

  def call(_args), do: {:error, "Unknown hub tool handler"}

  defp refresh_upstreams(nil) do
    upstreams = Pool.list_upstream_pids()

    for {pid, _status} <- upstreams do
      Upstream.refresh(pid)
    end

    {:ok, %{refreshed: length(upstreams), message: "Triggered refresh on all upstreams"}}
  end

  defp refresh_upstreams(name) when is_binary(name) do
    case Enum.find(Pool.list_upstream_pids(), fn {_pid, s} -> s.name == name end) do
      {pid, _status} ->
        Upstream.refresh(pid)
        {:ok, %{refreshed: 1, message: "Triggered refresh on upstream: #{name}"}}

      nil ->
        {:error, "Unknown upstream: #{name}"}
    end
  end

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
    |> select([s], {s.source, count(s.id), max(s.updated_at)})
    |> Repo.all()
    |> Enum.map(fn {source, count, last_synced} ->
      %{name: source, source: source, skill_count: count, last_synced: last_synced}
    end)
  rescue
    e ->
      Logger.warning("Failed to get skill sources: #{Exception.message(e)}")
      []
  end

  defp get_doc_projects do
    Project
    |> join(:left, [p], c in DocChunk, on: c.project_id == p.id)
    |> group_by([p], [p.id, p.last_indexed_at])
    |> select([p, c], %{id: p.id, chunk_count: count(c.id), last_indexed: p.last_indexed_at})
    |> Repo.all()
  rescue
    e ->
      Logger.warning("Failed to get doc projects: #{Exception.message(e)}")
      []
  end

  defp get_git_providers do
    providers = Application.get_env(:backplane, :git_providers, %{})

    Enum.flat_map([:github, :gitlab], fn type ->
      instances = Map.get(providers, type, [])
      Enum.map(instances, &format_provider_instance(type, &1))
    end)
  rescue
    e ->
      Logger.warning("Failed to get git providers: #{Exception.message(e)}")
      []
  end

  defp format_provider_instance(type, instance) do
    provider_name =
      "#{type}#{if instance.name != to_string(type), do: ".#{instance.name}", else: ""}"

    rate_info = RateLimitCache.get(provider_name)

    %{
      name: provider_name,
      type: to_string(type),
      api_url: instance.api_url,
      status: derive_provider_status(rate_info),
      rate_remaining: if(rate_info, do: rate_info.remaining)
    }
  end

  defp derive_provider_status(nil), do: "unknown"

  defp derive_provider_status(%{remaining: 0, reset: reset}) when is_integer(reset) do
    if reset > System.system_time(:second), do: "rate_limited", else: "ok"
  end

  defp derive_provider_status(_), do: "ok"

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
