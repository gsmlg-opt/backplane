defmodule BackplaneMonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Backplane.Monitor.PlanRegistry},
      {Task.Supervisor, name: Backplane.Monitor.TaskSupervisor},
      Backplane.Monitor.PlanSupervisor
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children,
             strategy: :one_for_one,
             name: BackplaneMonitor.Supervisor
           ) do
      Backplane.Monitor.PlanSupervisor.sync_plans()
      {:ok, pid}
    end
  end
end
