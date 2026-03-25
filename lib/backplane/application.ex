defmodule Backplane.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      Backplane.Registry.ToolRegistry,
      {Bandit, plug: Backplane.Transport.Router, port: port()}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    case System.get_env("BACKPLANE_PORT") do
      nil -> 4100
      port -> String.to_integer(port)
    end
  end
end
