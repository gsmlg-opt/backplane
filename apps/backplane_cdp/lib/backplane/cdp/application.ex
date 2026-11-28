defmodule Backplane.CDP.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: Backplane.CDP.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Backplane.CDP.Sessions, max_children: 256}
      ],
      strategy: :rest_for_one,
      name: Backplane.CDP.Supervisor
    )
  end
end
