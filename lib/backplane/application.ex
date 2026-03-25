defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  @drain_timeout 15_000

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      Backplane.Registry.ToolRegistry,
      Backplane.Skills.Registry,
      Backplane.Proxy.Pool,
      Backplane.Config.Watcher,
      {Bandit,
       plug: Backplane.Transport.Router,
       port: port(),
       thousand_island_options: [shutdown_timeout: @drain_timeout]}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register native tools after supervisor starts
    register_native_tools()

    # Start configured upstream MCP connections
    start_configured_upstreams()

    result
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutting down — draining connections (#{@drain_timeout}ms timeout)")

    # Pause Oban to stop picking up new jobs; running jobs finish naturally
    Oban.pause_all_queues(Oban)

    state
  rescue
    _ -> state
  end

  defp register_native_tools do
    alias Backplane.Registry.{Tool, ToolRegistry}

    tool_modules = [
      Backplane.Tools.Skill,
      Backplane.Tools.Docs,
      Backplane.Tools.Git,
      Backplane.Tools.Hub
    ]

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
      Backplane.Proxy.Pool.start_upstream(upstream)
    end
  end

  defp port do
    case System.get_env("BACKPLANE_PORT") do
      nil -> Application.get_env(:backplane, :port, 4100)
      port -> String.to_integer(port)
    end
  end
end
