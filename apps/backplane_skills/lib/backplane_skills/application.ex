defmodule BackplaneSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Skills.Registry,
      {Registry, keys: :unique, name: Backplane.Skills.AgentManage.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Backplane.Skills.AgentManage.DynamicSupervisor},
      Backplane.Skills.AgentManage.Bootstrap
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneSkills.Supervisor)
  end
end
