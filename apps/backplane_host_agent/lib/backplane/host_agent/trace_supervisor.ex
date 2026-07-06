defmodule Backplane.HostAgent.TraceSupervisor do
  @moduledoc """
  Starts host-agent trace storage and sync processes.
  """

  use Supervisor

  alias Backplane.HostAgent.{TraceStore, TraceSyncer}

  def start_link(%{enabled: false}), do: :ignore

  def start_link(%{} = telemetry_config) do
    opts = normalize(telemetry_config)
    name = Map.get(opts, :name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = [
      {TraceStore,
       dir: Map.fetch!(opts, :dir),
       retention_days: Map.fetch!(opts, :retention_days),
       name: Map.fetch!(opts, :store_name),
       handler_id: Map.fetch!(opts, :handler_id)},
      {TraceSyncer,
       dir: Map.fetch!(opts, :dir),
       config: opts,
       name: Map.fetch!(opts, :syncer_name),
       interval_ms: Map.fetch!(opts, :sync_interval_ms),
       batch_size: Map.fetch!(opts, :sync_batch_size)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize(telemetry_config) do
    telemetry_config
    |> Map.put_new(:store_name, TraceStore)
    |> Map.put_new(:syncer_name, TraceSyncer)
    |> Map.put_new(:handler_id, "backplane-host-agent-trace-store")
  end
end
