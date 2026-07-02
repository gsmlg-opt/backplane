defmodule BackplaneAuth.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Boruta.Cache is supervised by the :boruta application itself.
    Supervisor.start_link([], strategy: :one_for_one, name: BackplaneAuth.Supervisor)
  end
end
