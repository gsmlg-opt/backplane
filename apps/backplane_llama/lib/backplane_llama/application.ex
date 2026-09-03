defmodule BackplaneLlama.Application do
  @moduledoc false

  use Application

  alias Backplane.LLM.{LogWriter, UsageCollector}
  alias Backplane.Observability.{Buffer, Flags, Settings}

  @impl true
  def start(_type, _args) do
    children =
      [
        Relayixir,
        Backplane.LLM.ModelResolver,
        route_loader_child(),
        Backplane.LLM.RateLimiter
      ]
      |> maybe_llm_observability()
      |> Enum.reject(&is_nil/1)

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneLlama.Supervisor) do
      maybe_attach_usage_collector()
      {:ok, pid}
    end
  end

  defp route_loader_child do
    if Application.get_env(:backplane, :llm_route_loader_enabled, true) do
      Backplane.LLM.RouteLoader
    end
  end

  defp maybe_llm_observability(children) do
    if Flags.llm_write?() do
      children ++
        [
          {Buffer, [name: :llm_proxy, capacity: Settings.queue_capacity(:llm_proxy)]},
          {LogWriter, llm_log_writer_opts()}
        ]
    else
      children
    end
  end

  defp maybe_attach_usage_collector do
    if Flags.llm_write?() do
      :ok
    else
      UsageCollector.attach()
    end
  end

  defp llm_log_writer_opts do
    Application.get_env(:backplane_llama, :llm_log_writer, [])
  end
end
