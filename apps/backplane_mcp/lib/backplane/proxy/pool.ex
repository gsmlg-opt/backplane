defmodule Backplane.Proxy.Pool do
  @moduledoc """
  DynamicSupervisor managing upstream MCP server connections.
  """

  use DynamicSupervisor

  alias Backplane.Proxy.{ClientLeaseManager, Upstream}

  @prepare_stop_timeout 250

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
    if child?(pid) do
      ClientLeaseManager.mark_stopping(pid)
      prepare_stop(pid)
      ClientLeaseManager.cleanup(pid)
      result = DynamicSupervisor.terminate_child(__MODULE__, pid)
      ClientLeaseManager.finalize_owner(pid)
      result
    else
      {:error, :not_found}
    end
  end

  @doc false
  @spec child?(pid()) :: boolean()
  def child?(pid) when is_pid(pid) do
    Enum.any?(DynamicSupervisor.which_children(__MODULE__), fn
      {_id, ^pid, _type, _modules} -> true
      _other_child -> false
    end)
  end

  @doc "List status of all upstream connections."
  @spec list_upstreams() :: [map()]
  def list_upstreams do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid),
        status = safe_status(pid),
        status != nil do
      status
    end
  end

  @doc "List all running upstream pids with their status info."
  @spec list_upstream_pids() :: [{pid(), map()}]
  def list_upstream_pids do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid),
        status = safe_status(pid),
        status != nil do
      {pid, status}
    end
  end

  # Upstream may exit between which_children and status call
  defp safe_status(pid) do
    Upstream.status(pid)
  catch
    :exit, _ -> nil
  end

  defp prepare_stop(pid) do
    Upstream.prepare_stop(pid, @prepare_stop_timeout)
  catch
    :exit, _reason -> :ok
  end
end
