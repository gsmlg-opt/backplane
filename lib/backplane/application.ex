defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  alias Backplane.Config.Watcher
  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Skills.Sync
  alias Backplane.Tools.{Docs, Git, Hub, Skill}
  alias Backplane.Transport.Router

  @drain_timeout 15_000

  @impl true
  def start(_type, _args) do
    validate_config_at_boot()

    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      ToolRegistry,
      SkillsRegistry,
      Pool,
      Metrics,
      Watcher,
      {Bandit,
       plug: Router, port: port(), thousand_island_options: [shutdown_timeout: @drain_timeout]}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register native tools after supervisor starts
    register_native_tools()

    # Start configured upstream MCP connections
    start_configured_upstreams()

    # Enqueue initial skill sync jobs for configured sources
    enqueue_skill_syncs()

    result
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
    tool_modules = [Skill, Docs, Git, Hub]

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

  defp enqueue_skill_syncs do
    sources = Application.get_env(:backplane, :skill_sources, [])

    for source <- sources do
      case Sync.build_job(source) |> Oban.insert() do
        {:ok, _job} ->
          Logger.info("Enqueued skill sync for source: #{source.name}")

        {:error, reason} ->
          Logger.warning("Failed to enqueue skill sync for #{source.name}: #{inspect(reason)}")
      end
    end
  end

  defp validate_config_at_boot do
    config = [
      backplane: %{
        port: Application.get_env(:backplane, :port, 4100)
      },
      upstream: Application.get_env(:backplane, :upstreams, []),
      projects: Application.get_env(:backplane, :projects, []),
      skills: Application.get_env(:backplane, :skill_sources, [])
    ]

    Backplane.Config.Validator.validate!(config)
  end

  defp port do
    case System.get_env("BACKPLANE_PORT") do
      nil ->
        Application.get_env(:backplane, :port, 4100)

      port_str ->
        case Integer.parse(port_str) do
          {port, ""} when port > 0 and port <= 65_535 ->
            port

          _ ->
            Logger.warning("Invalid BACKPLANE_PORT '#{port_str}', using default 4100")
            4100
        end
    end
  end
end
