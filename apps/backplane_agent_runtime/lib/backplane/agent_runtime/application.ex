defmodule Backplane.AgentRuntime.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: Backplane.AgentRuntime.PluginRegistry}]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
