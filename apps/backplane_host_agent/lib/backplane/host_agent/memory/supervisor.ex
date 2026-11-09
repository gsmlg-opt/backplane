defmodule Backplane.HostAgent.Memory.Supervisor do
  @moduledoc """
  Starts the local memory store, runs boot migrations before returning, then
  starts the outbox sync loop.
  """

  use Supervisor

  alias Backplane.HostAgent.{HubProxy, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Migrator, OutboxSync, Store}

  @default_pool_size 1
  @default_busy_timeout_ms 5_000
  @default_sync_interval_ms 5_000
  @default_sync_batch_size 50

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
      {OutboxSync,
       name: Map.get(opts, :sync_name, OutboxSync),
       store: store_name,
       hub_proxy: Map.get(opts, :hub_proxy, HubProxy),
       memory_proxy: Map.get(opts, :memory_proxy, MemoryProxy),
       interval_ms: Map.get(opts, :sync_interval_ms, @default_sync_interval_ms),
       batch_size: Map.get(opts, :sync_batch_size, @default_sync_batch_size)}
    ]

    Elixir.Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize(memory_config) do
    memory_config
    |> Map.put_new(:store_name, Store)
    |> Map.put_new(:pool_size, @default_pool_size)
    |> Map.put_new(:busy_timeout_ms, @default_busy_timeout_ms)
  end
end
