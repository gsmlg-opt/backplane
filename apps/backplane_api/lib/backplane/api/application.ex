defmodule Backplane.Api.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Api.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Backplane.Api.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Backplane.Api.Endpoint.config_change(changed, removed)
    :ok
  end
end
