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
  def start_upstream(config) do
    spec = {Upstream, config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "List status of all upstream connections."
  def list_upstreams do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid) do
      Upstream.status(pid)
    end
  end
end
