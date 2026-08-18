defmodule Backplane.Proxy.ClientPool do
  @moduledoc """
  Supervises reusable MCP protocol client trees for configured upstreams.

  Children are temporary because `Backplane.Proxy.Upstream` owns reconnect and
  backoff policy. Each child remains an internal one-for-all protocol client
  tree, while independent upstream trees are isolated by this one-for-one
  dynamic supervisor.
  """

  use DynamicSupervisor

  alias Backplane.McpProtocol.Client

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a temporary MCP protocol client supervision tree."
  @spec start_client(keyword()) :: DynamicSupervisor.on_start_child()
  def start_client(opts) do
    spec = Client.child_spec(opts) |> Map.put(:restart, :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop a protocol client supervision tree by pid."
  @spec stop_client(pid()) :: :ok | {:error, :not_found}
  def stop_client(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
