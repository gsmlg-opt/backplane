defmodule Backplane.Clients.AuthSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor,
       name: Backplane.Clients.Tasks,
       max_children: Backplane.Clients.AuthCache.options()[:max_workers] + 2},
      {Backplane.Clients.AuthCache, []},
      {Backplane.Clients.Activity, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
