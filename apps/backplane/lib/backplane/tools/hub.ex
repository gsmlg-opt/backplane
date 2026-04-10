defmodule Backplane.Tools.Hub do
  @moduledoc """
  Native MCP tools for hub-level discovery and introspection.
  """

  @behaviour Backplane.Tools.ToolModule

  require Logger

  alias Backplane.Hub.{Discover, Inspect}
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
        description: "Unified search across tools and skills",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search keywords"},
            "scope" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter to specific scopes: tools, skills"
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
      },
      %{
        name: "hub::cache-status",
        description: "Get response cache statistics (hit rate, size, evictions)",
        input_schema: %{
          "type" => "object",
          "properties" => %{}
        },
        module: __MODULE__,
        handler: :cache_status
      },
      %{
        name: "hub::cache-flush",
        description: "Flush the response cache. Optionally flush only a specific prefix.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "prefix" => %{
              "type" => "string",
              "description" =>
                "Flush only entries matching this upstream prefix or provider name. Omit to flush all."
            }
          }
        },
        module: __MODULE__,
        handler: :cache_flush
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

    {:ok,
     %{
       upstreams: upstreams,
       skill_sources: skill_sources,
       total_tools: ToolRegistry.count(),
       total_skills: Registry.count(),
       version: Backplane.version()
     }}
  end

  def call(%{"_handler" => "refresh"} = args) do
    refresh_upstreams(args["upstream"])
  end

  def call(%{"_handler" => "cache_status"}) do
    stats = Backplane.Cache.stats()

    {:ok,
     %{
       hits: stats.hits,
       misses: stats.misses,
       hit_rate: stats.hit_rate,
       entry_count: stats.size,
       max_entries: Application.get_env(:backplane, :cache_max_entries, 10_000),
       evictions: stats.evictions
     }}
  end

  def call(%{"_handler" => "cache_flush"} = args) do
    case args["prefix"] do
      nil ->
        count = Backplane.Cache.flush()
        {:ok, %{flushed_count: count}}

      prefix ->
        # Build a prefix tuple for invalidation
        count = Backplane.Cache.invalidate_prefix({:upstream, prefix})
        {:ok, %{flushed_count: count}}
    end
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

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
