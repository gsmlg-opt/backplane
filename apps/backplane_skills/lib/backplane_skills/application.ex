defmodule BackplaneSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Skills.Registry,
      Backplane.Skills.HostConnectionRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneSkills.Supervisor)
  end
end
