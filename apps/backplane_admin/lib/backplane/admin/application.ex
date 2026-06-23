defmodule Backplane.Admin.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Admin.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Backplane.Admin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Backplane.Admin.Endpoint.config_change(changed, removed)
    :ok
  end
end
