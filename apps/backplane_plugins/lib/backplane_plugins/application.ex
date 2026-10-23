defmodule BackplanePlugins.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children =
      if Application.get_env(:backplane_plugins, :sync_enabled, true),
        do: [Backplane.Plugins.Scheduler],
        else: []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BackplanePlugins.Supervisor
    )
  end
end
