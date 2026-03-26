defmodule Backplane.Proxy.Pool do
  @moduledoc """
  DynamicSupervisor managing upstream MCP server connections.
  """

  use DynamicSupervisor

  alias Backplane.Proxy.Upstream

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new upstream connection."
  @spec start_upstream(map()) :: DynamicSupervisor.on_start_child()
  def start_upstream(config) do
    spec = {Upstream, config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop an upstream connection by pid."
  @spec stop_upstream(pid()) :: :ok | {:error, :not_found}
  def stop_upstream(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "List status of all upstream connections."
  @spec list_upstreams() :: [map()]
  def list_upstreams do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid) do
      Upstream.status(pid)
    end
  end

  @doc "List all running upstream pids with their status info."
  @spec list_upstream_pids() :: [{pid(), map()}]
  def list_upstream_pids do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid) do
      {pid, Upstream.status(pid)}
    end
  end
end
