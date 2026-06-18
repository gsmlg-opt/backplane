defmodule Backplane.HostAgent.Memory.Supervisor do
  @moduledoc """
  Starts the local memory store and runs boot migrations before returning.
  """

  use Supervisor

  alias Backplane.HostAgent.Memory.{Migrator, Pruner, Store, Syncer}

  @default_pool_size 1
  @default_busy_timeout_ms 5_000

  def start_link(%{enabled: false}), do: :ignore

  def start_link(%{} = memory_config) do
    opts = normalize(memory_config)
    name = Map.get(opts, :name, __MODULE__)

    Elixir.Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store_name = Map.fetch!(opts, :store_name)

    children = [
      {Store,
       database: Map.fetch!(opts, :db_path),
       name: store_name,
       pool_size: Map.get(opts, :pool_size, @default_pool_size),
       busy_timeout_ms: Map.get(opts, :busy_timeout_ms, @default_busy_timeout_ms)},
      {Migrator, store: store_name},
      {Syncer,
       store: store_name,
       config: opts,
       name: Map.fetch!(opts, :syncer_name),
       interval_ms: Map.get(opts, :sync_interval_ms),
       batch_size: Map.get(opts, :sync_batch_size),
       max_attempts: Map.get(opts, :max_attempts)},
      {Pruner, store: store_name, config: opts, name: Map.fetch!(opts, :pruner_name)}
    ]

    Elixir.Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize(memory_config) do
    memory_config
    |> Map.put_new(:store_name, Store)
    |> Map.put_new_lazy(:syncer_name, fn ->
      :"#{Map.get(memory_config, :store_name, Store)}_syncer"
    end)
    |> Map.put_new_lazy(:pruner_name, fn ->
      :"#{Map.get(memory_config, :store_name, Store)}_pruner"
    end)
    |> Map.put_new(:pool_size, @default_pool_size)
    |> Map.put_new(:busy_timeout_ms, @default_busy_timeout_ms)
  end
end
