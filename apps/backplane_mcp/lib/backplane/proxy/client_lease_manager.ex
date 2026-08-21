defmodule Backplane.Proxy.ClientLeaseManager do
  @moduledoc false

  use GenServer

  alias Backplane.Proxy.{ClientPool, Pool}
  alias Backplane.Registry.ToolRegistry

  @call_timeout 5_000
  @registry_cleanup_timeout 500
  @retry_delay 10

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec start_client(pid(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_client(owner, prefix, client_opts)
      when is_pid(owner) and is_binary(prefix) and is_list(client_opts) do
    GenServer.call(__MODULE__, {:start_client, owner, prefix, client_opts}, @call_timeout)
  end

  @spec stop_client(pid(), pid()) :: :ok
  def stop_client(owner, client_supervisor)
      when is_pid(owner) and is_pid(client_supervisor) do
    GenServer.call(__MODULE__, {:stop_client, owner, client_supervisor}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @spec detach_client(pid(), pid()) :: :ok
  def detach_client(owner, client_supervisor)
      when is_pid(owner) and is_pid(client_supervisor) do
    GenServer.call(__MODULE__, {:detach_client, owner, client_supervisor}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @spec cleanup(pid()) :: :ok
  def cleanup(owner) when is_pid(owner) do
    GenServer.call(__MODULE__, {:cleanup, owner}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @spec mark_stopping(pid()) :: :ok | :not_found
  def mark_stopping(owner) when is_pid(owner) do
    GenServer.call(__MODULE__, {:mark_stopping, owner}, @call_timeout)
  catch
    :exit, _reason -> :not_found
  end

  @spec finalize_owner(pid()) :: :ok
  def finalize_owner(owner) when is_pid(owner) do
    GenServer.call(__MODULE__, {:finalize_owner, owner}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts) do
    state = %{leases: %{}, refs: %{}, client_pool_ref: monitor_client_pool()}
    {:ok, restore_snapshots(state)}
  end

  @impl true
  def handle_call({:start_client, owner, prefix, client_opts}, _from, state) do
    if pool_child?(owner) do
      case reserve_owner(state, owner, prefix) do
        {:ok, state} ->
          case safe_start_client(client_opts, owner, prefix) do
            {:ok, client_supervisor} = started ->
              attach_started_client(state, owner, prefix, client_supervisor, started)

            {:error, _reason} = error ->
              {:reply, error, state}
          end

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_owned}, state}
    end
  end

  def handle_call({:stop_client, owner, client_supervisor}, _from, state) do
    state = clear_client(state, owner, client_supervisor, stop?: true)
    {:reply, :ok, state}
  end

  def handle_call({:detach_client, owner, client_supervisor}, _from, state) do
    state = clear_client(state, owner, client_supervisor, stop?: false)
    {:reply, :ok, state}
  end

  def handle_call({:cleanup, owner}, _from, state) do
    case Map.get(state.leases, owner) do
      %{stopping: true, prefix: prefix, client_supervisor: client_supervisor} ->
        state = clear_client(state, owner, client_supervisor, stop?: true)
        ToolRegistry.deregister_upstream(prefix, owner)
        await_registry_cleanup(prefix)
        {:reply, :ok, state}

      _ordinary_or_missing ->
        {state, prefix} = cleanup_owner(state, owner)
        await_registry_cleanup(prefix)
        {:reply, :ok, state}
    end
  end

  def handle_call({:mark_stopping, owner}, _from, state) do
    case Map.get(state.leases, owner) do
      nil ->
        {:reply, :not_found, state}

      lease ->
        stopping = %{lease | stopping: true}

        if persist_lease(owner, stopping) do
          {:reply, :ok, put_lease(state, owner, stopping)}
        else
          {:reply, :not_found, state}
        end
    end
  end

  def handle_call({:finalize_owner, owner}, _from, state) do
    {state, prefix} = cleanup_owner(state, owner)
    await_registry_cleanup(prefix)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:owned_client_attached, owner, prefix, client_supervisor}, state) do
    case Map.get(state.leases, owner) do
      %{prefix: ^prefix, client_supervisor: nil, stopping: false} = lease ->
        if Process.alive?(owner) and Process.alive?(client_supervisor) do
          client_ref = Process.monitor(client_supervisor)

          attached = %{
            lease
            | client_supervisor: client_supervisor,
              client_ref: client_ref
          }

          {:noreply, put_lease(state, owner, attached)}
        else
          safe_stop_client(client_supervisor)
          {state, _prefix} = cleanup_owner(state, owner)
          {:noreply, state}
        end

      %{prefix: ^prefix, client_supervisor: ^client_supervisor} ->
        {:noreply, state}

      _missing_stopping_or_replaced ->
        safe_stop_client(client_supervisor)
        ToolRegistry.deregister_upstream(prefix, owner)
        ClientPool.delete_owned_lease_snapshot(owner, prefix, client_supervisor)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.refs, ref) do
      {:owner, owner} ->
        {state, _prefix} = cleanup_owner(state, owner, down_ref: ref)
        {:noreply, state}

      {:client, owner, client_supervisor} ->
        {:noreply,
         clear_client(state, owner, client_supervisor,
           stop?: false,
           down_ref: ref
         )}

      nil when state.client_pool_ref == ref ->
        Process.send_after(self(), :recover_client_pool, @retry_delay)
        {:noreply, %{state | client_pool_ref: nil}}

      _stale_ref ->
        {:noreply, state}
    end
  end

  def handle_info(:recover_client_pool, state) do
    case Process.whereis(ClientPool) do
      client_pool when is_pid(client_pool) ->
        state = recover_client_pool(state, client_pool)
        {:noreply, state}

      _not_ready ->
        Process.send_after(self(), :recover_client_pool, @retry_delay)
        {:noreply, state}
    end
  end

  defp reserve_owner(state, owner, prefix) do
    case cleanup_stale_prefix(state, prefix, owner) do
      {:ok, state} ->
        case Map.get(state.leases, owner) do
          %{stopping: true} ->
            {:error, :owner_stopping, state}

          %{prefix: ^prefix, client_supervisor: nil} ->
            {:ok, state}

          %{prefix: ^prefix, client_supervisor: client_supervisor}
          when is_pid(client_supervisor) ->
            {:error, :client_already_started, state}

          nil ->
            owner_ref = Process.monitor(owner)

            lease = %{
              prefix: prefix,
              client_supervisor: nil,
              owner_ref: owner_ref,
              client_ref: nil,
              stopping: false
            }

            if persist_lease(owner, lease) do
              {:ok, put_lease(state, owner, lease)}
            else
              Process.demonitor(owner_ref, [:flush])
              {:error, :lease_snapshot_unavailable, state}
            end
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp cleanup_stale_prefix(state, prefix, current_owner) do
    Enum.reduce_while(state.leases, {:ok, state}, fn
      {^current_owner, _lease}, {:ok, state} ->
        {:cont, {:ok, state}}

      {owner, %{prefix: ^prefix}}, {:ok, state} ->
        if Process.alive?(owner) do
          {:halt, {:error, :prefix_in_use, state}}
        else
          {state, _prefix} = cleanup_owner(state, owner)
          {:cont, {:ok, state}}
        end

      _other_lease, {:ok, state} ->
        {:cont, {:ok, state}}
    end)
  end

  defp attach_started_client(state, owner, prefix, client_supervisor, started) do
    if Process.alive?(owner) and pool_child?(owner) do
      client_ref = Process.monitor(client_supervisor)
      lease = Map.fetch!(state.leases, owner)

      attached = %{
        lease
        | client_supervisor: client_supervisor,
          client_ref: client_ref
      }

      if ClientPool.lease_snapshot(owner) == {prefix, client_supervisor} do
        {:reply, started, put_lease(state, owner, attached)}
      else
        Process.demonitor(client_ref, [:flush])
        safe_stop_client(client_supervisor)
        {state, _prefix} = cleanup_owner(state, owner)
        {:reply, {:error, :lease_snapshot_unavailable}, state}
      end
    else
      safe_stop_client(client_supervisor)
      {state, _prefix} = cleanup_owner(state, owner)
      {:reply, {:error, :owner_stopped}, state}
    end
  end

  defp clear_client(state, owner, client_supervisor, opts) do
    case Map.get(state.leases, owner) do
      %{client_supervisor: ^client_supervisor} = lease ->
        state = drop_ref(state, lease.client_ref, Keyword.get(opts, :down_ref))

        if Keyword.fetch!(opts, :stop?) do
          safe_stop_client(client_supervisor)
        end

        ToolRegistry.deregister_upstream(lease.prefix, owner)
        cleared = %{lease | client_supervisor: nil, client_ref: nil}
        _stored? = persist_lease(owner, cleared)

        put_lease(state, owner, cleared)

      _missing_or_replaced ->
        state
    end
  end

  defp cleanup_owner(state, owner, opts \\ []) do
    case Map.pop(state.leases, owner) do
      {nil, _leases} ->
        {state, nil}

      {lease, leases} ->
        state = %{state | leases: leases}
        state = drop_ref(state, lease.owner_ref, Keyword.get(opts, :down_ref))
        state = drop_ref(state, lease.client_ref, nil)
        safe_stop_client(lease.client_supervisor)
        ToolRegistry.deregister_upstream(lease.prefix, owner)
        ClientPool.delete_lease_snapshot(owner)
        {state, lease.prefix}
    end
  end

  defp restore_snapshots(state) do
    Enum.reduce(ClientPool.lease_snapshots(), state, fn
      {owner, prefix, client_supervisor, stopping}, state
      when is_pid(owner) and is_binary(prefix) and is_boolean(stopping) ->
        if Process.alive?(owner) do
          owner_ref = Process.monitor(owner)

          {client_supervisor, client_ref} =
            if is_pid(client_supervisor) and Process.alive?(client_supervisor) do
              {client_supervisor, Process.monitor(client_supervisor)}
            else
              ToolRegistry.deregister_upstream(prefix, owner)
              ClientPool.put_lease_snapshot(owner, prefix, nil, stopping)
              {nil, nil}
            end

          lease = %{
            prefix: prefix,
            client_supervisor: client_supervisor,
            owner_ref: owner_ref,
            client_ref: client_ref,
            stopping: stopping
          }

          put_lease(state, owner, lease)
        else
          safe_stop_client(client_supervisor)
          ToolRegistry.deregister_upstream(prefix, owner)
          ClientPool.delete_lease_snapshot(owner)
          state
        end

      _invalid_snapshot, state ->
        state
    end)
  end

  defp recover_client_pool(state, client_pool) do
    client_pool_ref = Process.monitor(client_pool)

    state =
      Enum.reduce(state.leases, state, fn {owner, lease}, state ->
        if is_pid(lease.client_supervisor) and not Process.alive?(lease.client_supervisor) do
          clear_client(state, owner, lease.client_supervisor, stop?: false)
        else
          _stored? = persist_lease(owner, lease)

          state
        end
      end)

    %{state | client_pool_ref: client_pool_ref}
  end

  defp put_lease(state, owner, lease) do
    refs =
      state.refs
      |> maybe_put_ref(lease.owner_ref, {:owner, owner})
      |> maybe_put_ref(lease.client_ref, {:client, owner, lease.client_supervisor})

    %{state | leases: Map.put(state.leases, owner, lease), refs: refs}
  end

  defp drop_ref(state, nil, _down_ref), do: state

  defp drop_ref(state, ref, down_ref) do
    if ref != down_ref, do: Process.demonitor(ref, [:flush])
    %{state | refs: Map.delete(state.refs, ref)}
  end

  defp maybe_put_ref(refs, nil, _value), do: refs
  defp maybe_put_ref(refs, ref, value), do: Map.put(refs, ref, value)

  defp safe_start_client(client_opts, owner, prefix) do
    ClientPool.start_owned_client(client_opts, owner, prefix)
  rescue
    _exception -> {:error, :client_pool_unavailable}
  catch
    :exit, _reason -> {:error, :client_pool_unavailable}
  end

  defp persist_lease(owner, lease) do
    ClientPool.put_lease_snapshot(
      owner,
      lease.prefix,
      lease.client_supervisor,
      lease.stopping
    )
  end

  defp safe_stop_client(client_supervisor) when is_pid(client_supervisor) do
    if Process.alive?(client_supervisor) do
      try do
        _ = ClientPool.stop_client(client_supervisor)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp safe_stop_client(_missing), do: :ok

  defp pool_child?(owner) do
    Pool.child?(owner)
  catch
    :exit, _reason -> false
  end

  defp monitor_client_pool do
    case Process.whereis(ClientPool) do
      client_pool when is_pid(client_pool) -> Process.monitor(client_pool)
      _missing -> nil
    end
  end

  defp await_registry_cleanup(nil), do: :ok

  defp await_registry_cleanup(prefix) do
    deadline = System.monotonic_time(:millisecond) + @registry_cleanup_timeout
    do_await_registry_cleanup(prefix, deadline)
  end

  defp do_await_registry_cleanup(prefix, deadline) do
    clean? =
      Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}) == [] and
        Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport}) == []

    if clean? or System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(10)
      do_await_registry_cleanup(prefix, deadline)
    end
  end
end
