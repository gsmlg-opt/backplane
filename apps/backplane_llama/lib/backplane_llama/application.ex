defmodule BackplaneLlama.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Relayixir,
        Backplane.LLM.ModelResolver,
        route_loader_child(),
        Backplane.LLM.RateLimiter,
        {Backplane.LLM.HealthChecker, []}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneLlama.Supervisor)
  end

  defp route_loader_child do
    if Application.get_env(:backplane, :llm_route_loader_enabled, true) do
      Backplane.LLM.RouteLoader
    end
  end
end
