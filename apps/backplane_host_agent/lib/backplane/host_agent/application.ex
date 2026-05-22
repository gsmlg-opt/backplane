defmodule Backplane.HostAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.HostAgent.Worker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Backplane.HostAgent.Supervisor)
  end
end
