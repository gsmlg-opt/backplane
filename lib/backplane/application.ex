defmodule Backplane.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      Backplane.Registry.ToolRegistry,
      Backplane.Skills.Registry,
      Backplane.Proxy.Pool,
      {Bandit, plug: Backplane.Transport.Router, port: port()}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register native tools after supervisor starts
    register_native_tools()

    result
  end

  defp register_native_tools do
    alias Backplane.Registry.{Tool, ToolRegistry}

    tool_modules = [Backplane.Tools.Skill, Backplane.Tools.Docs, Backplane.Tools.Git]

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

  defp port do
    case System.get_env("BACKPLANE_PORT") do
      nil -> 4100
      port -> String.to_integer(port)
    end
  end
end
