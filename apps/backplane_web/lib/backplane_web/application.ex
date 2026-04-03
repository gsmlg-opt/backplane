defmodule BackplaneWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BackplaneWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BackplaneWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BackplaneWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
