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

  @lease_table :backplane_client_leases

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@lease_table, [:named_table, :set, :public, read_concurrency: true])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a temporary MCP protocol client supervision tree."
  @spec start_client(keyword()) :: DynamicSupervisor.on_start_child()
  def start_client(opts) do
    spec = Client.child_spec(opts) |> Map.put(:restart, :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc false
  @spec start_owned_client(keyword(), pid(), String.t()) :: DynamicSupervisor.on_start_child()
  def start_owned_client(opts, owner, prefix)
      when is_pid(owner) and is_binary(prefix) do
    spec = Client.child_spec(opts) |> Map.put(:restart, :temporary)
    %{start: start} = spec

    owned_spec = %{
      spec
      | start: {__MODULE__, :start_owned_child, [start, owner, prefix]}
    }

    DynamicSupervisor.start_child(__MODULE__, owned_spec)
  end

  @doc false
  def start_owned_child({module, function, arguments}, owner, prefix) do
    case apply(module, function, arguments) do
      {:ok, client_supervisor} = started ->
        attach_owned_child(started, client_supervisor, owner, prefix)

      {:ok, client_supervisor, _info} = started ->
        attach_owned_child(started, client_supervisor, owner, prefix)

      other ->
        other
    end
  end

  @doc false
  @spec put_lease_snapshot(pid(), String.t(), pid() | nil) :: true | false
  def put_lease_snapshot(owner, prefix, client_supervisor)
      when is_pid(owner) and is_binary(prefix) and
             (is_pid(client_supervisor) or is_nil(client_supervisor)) do
    put_lease_snapshot(owner, prefix, client_supervisor, false)
  end

  @doc false
  @spec put_lease_snapshot(pid(), String.t(), pid() | nil, boolean()) :: true | false
  def put_lease_snapshot(owner, prefix, client_supervisor, stopping)
      when is_pid(owner) and is_binary(prefix) and
             (is_pid(client_supervisor) or is_nil(client_supervisor)) and
             is_boolean(stopping) do
    lease_access(false, fn ->
      :ets.insert(@lease_table, {owner, prefix, client_supervisor, stopping})
    end)
  end

  @doc false
  @spec delete_lease_snapshot(pid()) :: true | false
  def delete_lease_snapshot(owner) when is_pid(owner) do
    lease_access(false, fn -> :ets.delete(@lease_table, owner) end)
  end

  @doc false
  @spec lease_snapshot(pid()) :: {String.t(), pid() | nil} | nil
  def lease_snapshot(owner) when is_pid(owner) do
    case lease_access([], fn -> :ets.lookup(@lease_table, owner) end) do
      [{^owner, prefix, client_supervisor, _stopping}] -> {prefix, client_supervisor}
      [] -> nil
    end
  end

  @doc false
  @spec lease_snapshots() :: [{pid(), String.t(), pid() | nil, boolean()}]
  def lease_snapshots do
    lease_access([], fn -> :ets.tab2list(@lease_table) end)
  end

  @doc "Stop a protocol client supervision tree by pid."
  @spec stop_client(pid()) :: :ok | {:error, :not_found}
  def stop_client(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  defp attach_owned_child(started, client_supervisor, owner, prefix) do
    replaced =
      lease_access(0, fn ->
        :ets.select_replace(@lease_table, [
          {{owner, prefix, nil, false}, [], [{{owner, prefix, client_supervisor, false}}]}
        ])
      end)

    if replaced == 1 and Process.alive?(owner) do
      notify_lease_manager(owner, prefix, client_supervisor)
      started
    else
      delete_owned_lease_snapshot(owner, prefix, client_supervisor)
      Supervisor.stop(client_supervisor, :shutdown)
      {:error, :upstream_not_owned}
    end
  end

  @doc false
  @spec delete_owned_lease_snapshot(pid(), String.t(), pid()) :: non_neg_integer()
  def delete_owned_lease_snapshot(owner, prefix, client_supervisor)
      when is_pid(owner) and is_binary(prefix) and is_pid(client_supervisor) do
    lease_access(0, fn ->
      :ets.select_delete(@lease_table, [
        {{owner, prefix, client_supervisor, false}, [], [true]}
      ])
    end)
  end

  defp notify_lease_manager(owner, prefix, client_supervisor) do
    if manager = Process.whereis(Backplane.Proxy.ClientLeaseManager) do
      send(manager, {:owned_client_attached, owner, prefix, client_supervisor})
    end

    :ok
  end

  defp lease_access(missing, fun) do
    case :ets.whereis(@lease_table) do
      :undefined -> missing
      _table -> fun.()
    end
  rescue
    ArgumentError -> missing
  end
end
