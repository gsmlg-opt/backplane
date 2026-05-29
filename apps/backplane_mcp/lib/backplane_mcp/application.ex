defmodule BackplaneMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    cache_opts = [
      max_entries: Application.get_env(:backplane, :cache_max_entries, 10_000)
    ]

    children = [
      Backplane.Transport.Session,
      Backplane.Transport.TaskManager,
      Backplane.Math.Supervisor,
      Backplane.Proxy.Pool,
      {Backplane.Cache, cache_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneMcp.Supervisor)
  end
end
