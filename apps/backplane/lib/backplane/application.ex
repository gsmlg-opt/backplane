defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  alias Backplane.Config.Validator
  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Tools.{Admin, Hub, Skill}

  @drain_timeout 15_000

  @impl true
  def start(_type, _args) do
    validate_config_at_boot()

    cache_opts = [
      max_entries: Application.get_env(:backplane, :cache_max_entries, 10_000)
    ]

    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      {Phoenix.PubSub, name: Backplane.PubSub},
      Backplane.Settings.TokenCache,
      Backplane.Settings,
      ToolRegistry,
      Backplane.Math.Supervisor,
      SkillsRegistry,
      Pool,
      {Backplane.Cache, cache_opts},
      Metrics,
      Relayixir,
      Backplane.LLM.ModelResolver,
      Backplane.LLM.RouteLoader,
      Backplane.LLM.RateLimiter,
      {Backplane.LLM.HealthChecker, []}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Register native tools after supervisor starts
      register_native_tools()

      # Register managed service tools
      register_managed_services()

      # Start configured upstream MCP connections
      start_configured_upstreams()

      # Start DB-backed upstream MCP connections
      start_db_upstreams()

      # Attach telemetry handlers for usage collection
      Backplane.LLM.UsageCollector.attach()

      # Initialize clients ETS cache and upsert pre-seeded clients
      Backplane.Clients.init_cache()
      upsert_config_clients()

      {:ok, pid}
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutting down — draining connections (#{@drain_timeout}ms timeout)")

    # Pause Oban to stop picking up new jobs; running jobs finish naturally
    Oban.pause_all_queues(Oban)

    state
  rescue
    e ->
      Logger.warning("Error during prep_stop: #{Exception.message(e)}")
      state
  end

  defp register_native_tools do
    math_modules = if Backplane.Math.Tools.enabled?(), do: [Backplane.Math.Tools], else: []
    tool_modules = [Skill, Hub, Admin] ++ math_modules

    for module <- tool_modules, tool_def <- module.tools() do
      tool = %Tool{
        name: tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema,
        origin: :native,
        module: tool_def.module,
        handler: tool_def.handler
      }

      ToolRegistry.register_native(tool)
    end
  end

  defp start_configured_upstreams do
    upstreams = Application.get_env(:backplane, :upstreams, [])

    for upstream <- upstreams do
      Pool.start_upstream(upstream)
    end
  end

  defp upsert_config_clients do
    seeds = Application.get_env(:backplane, :client_seeds, [])

    for %{name: name} = seed when is_binary(name) <- seeds do
      case Backplane.Clients.upsert_from_config(seed) do
        {:ok, _client} ->
          Logger.info("Upserted client from config: #{name}")

        {:error, reason} ->
          Logger.warning("Failed to upsert client #{name}: #{inspect(reason)}")
      end
    end
  end

  defp register_managed_services do
    services = [Backplane.Services.Day]

    for service <- services, service.enabled?() do
      ToolRegistry.register_managed(service.prefix(), service.tools())
    end
  end

  defp start_db_upstreams do
    for upstream <- Backplane.Proxy.Upstreams.list_enabled() do
      config = %{
        name: upstream.name,
        prefix: upstream.prefix,
        transport: upstream.transport,
        url: upstream.url,
        command: upstream.command,
        args: upstream.args || [],
        timeout: upstream.timeout_ms,
        refresh_interval: upstream.refresh_interval_ms,
        headers: upstream.headers || %{},
        credential: upstream.credential,
        auth_scheme: upstream.auth_scheme || "none",
        auth_header_name: upstream.auth_header_name
      }

      Pool.start_upstream(config)
    end
  rescue
    e ->
      Logger.warning("Failed to load DB upstreams: #{Exception.message(e)}")
  end

  defp validate_config_at_boot do
    config = [
      backplane: %{
        port: Application.get_env(:backplane, :port, 4100)
      },
      upstream: Application.get_env(:backplane, :upstreams, [])
    ]

    Validator.validate!(config)
  end
end
