defmodule Backplane.AgentRuntime.Codex.ResourceRegistry do
  use GenServer

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Process-local run resources with owner/incarnation fencing and bounded cleanup.

  Cleanup capabilities stay in this process tree. Failed or unconfirmed cleanup
  leaves an inspection record; callers must reconcile it before replacing a run.
  """

  @default_cleanup_timeout 5_000
  @max_settled 256

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def register(pid, owner, kind, value, opts \\ []),
    do: GenServer.call(pid, {:register, owner, kind, value, opts})

  def fetch(pid, handle, owner), do: GenServer.call(pid, {:fetch, handle, owner})
  def release(pid, handle, owner), do: GenServer.call(pid, {:release, handle, owner}, :infinity)
  def cancel_owner(pid, owner), do: GenServer.call(pid, {:cancel_owner, owner}, :infinity)

  def cleanup_status(pid, handle, owner),
    do: GenServer.call(pid, {:cleanup_status, handle, owner})

  def owner_status(pid, owner), do: GenServer.call(pid, {:owner_status, owner})
  def worker_supervisor(pid), do: GenServer.call(pid, :worker_supervisor)

  def register_session(pid, owner, value, opts \\ []),
    do: GenServer.call(pid, {:register_session, owner, value, opts})

  def fetch_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:fetch_session, session_id, owner, incarnation})

  def update_session(pid, session_id, owner, value, incarnation \\ nil),
    do: GenServer.call(pid, {:update_session, session_id, owner, value, incarnation})

  def forget_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:forget_session, session_id, owner, incarnation})

  def release_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:release_session, session_id, owner, incarnation}, :infinity)

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :cleanup_timeout, @default_cleanup_timeout)

    if is_integer(timeout) and timeout > 0 and timeout <= 60_000 do
      {:ok, cleanup_supervisor} = Task.Supervisor.start_link()
      {:ok, worker_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

      {:ok,
       %{
         resources: %{},
         sessions: %{},
         settled: %{},
         settled_order: :queue.new(),
         tasks: %{},
         registry_pid: self(),
         cleanup_supervisor: cleanup_supervisor,
         worker_supervisor: worker_supervisor,
         cleanup_timeout: timeout
       }}
    else
      {:stop, Error.new(:validation, "cleanup_timeout must be between 1 and 60000 ms")}
    end
  end

  @impl true
  def handle_call(:worker_supervisor, _from, state),
    do: {:reply, {:ok, state.worker_supervisor}, state}

  def handle_call({:register, owner, kind, value, opts}, _from, state)
      when is_binary(owner) and owner != "" and is_atom(kind) do
    incarnation = Keyword.get(opts, :incarnation, 1)
    cleanup = Keyword.get(opts, :cleanup)

    with :ok <- validate_incarnation(incarnation), :ok <- validate_cleanup(cleanup) do
      id = "res_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      handle = %{resource_id: id, owner_id: owner, incarnation: incarnation, kind: kind}
      entry = entry(handle, value, cleanup, Keyword.get(opts, :owner_pid))
      {:reply, {:ok, handle}, put_entry(state, {:resource, id}, entry)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:fetch, handle, owner}, _from, state) do
    with {:ok, entry} <- lookup_resource(state, handle, owner),
         :ok <- active(entry) do
      {:reply, {:ok, entry.value}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cleanup_status, handle, owner}, _from, state) do
    with {:ok, entry} <- lookup_resource(state, handle, owner) do
      {:reply, {:ok, Map.take(entry, [:status, :reason])}, state}
    else
      {:error, %Error{class: :not_found}} ->
        case Map.get(state.settled, {:resource, handle[:resource_id]}) do
          %{owner_id: ^owner, handle: stored} = settled when is_map(handle) ->
            if stored.incarnation == handle[:incarnation],
              do: {:reply, {:ok, Map.take(settled, [:status, :reason])}, state},
              else:
                {:reply, {:error, Error.new(:resource_conflict, "stale resource incarnation")},
                 state}

          _ ->
            {:reply, {:error, Error.new(:not_found, "resource handle is unknown")}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:owner_status, owner}, _from, state) do
    statuses =
      all_entries(state)
      |> Enum.filter(fn {_key, entry} -> entry.owner_id == owner end)
      |> Enum.map(fn {key, entry} ->
        %{id: elem(key, 1), kind: elem(key, 0), status: entry.status, reason: entry.reason}
      end)

    {:reply, {:ok, statuses}, state}
  end

  def handle_call({:register_session, owner, value, opts}, _from, state)
      when is_binary(owner) and owner != "" and is_list(opts) do
    cleanup = Keyword.get(opts, :cleanup)

    with :ok <- validate_cleanup(cleanup),
         :ok <- validate_incarnation(Keyword.get(opts, :incarnation, 1)) do
      id = System.unique_integer([:positive, :monotonic])
      handle = %{session_id: id, owner_id: owner, incarnation: Keyword.get(opts, :incarnation, 1)}
      entry = entry(handle, value, cleanup, Keyword.get(opts, :owner_pid))
      {:reply, {:ok, id}, put_entry(state, {:session, id}, entry)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:register_session, _, _, _}, _from, state),
    do: {:reply, {:error, Error.new(:validation, "session owner is required")}, state}

  def handle_call({:fetch_session, id, owner, incarnation}, _from, state) do
    with {:ok, entry} <- lookup_session(state, id, owner, incarnation), :ok <- active(entry) do
      {:reply, {:ok, entry.value}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:update_session, id, owner, value, incarnation}, _from, state) do
    with {:ok, entry} <- lookup_session(state, id, owner, incarnation), :ok <- active(entry) do
      {:reply, :ok, put_entry(state, {:session, id}, %{entry | value: value})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:forget_session, id, owner, incarnation}, _from, state) do
    with {:ok, entry} <- lookup_session(state, id, owner, incarnation), :ok <- active(entry) do
      {:reply, :ok, remove_entry(state, {:session, id}, entry, :confirmed)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:release_session, id, owner, incarnation}, from, state) do
    case lookup_session(state, id, owner, incarnation) do
      {:ok, _entry} -> {:noreply, request_cleanup(state, {:session, id}, from)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:release, handle, owner}, from, state) do
    key = {:resource, handle[:resource_id]}

    case lookup_resource(state, handle, owner) do
      {:ok, _entry} ->
        {:noreply, request_cleanup(state, key, from)}

      {:error, %Error{class: :not_found}} = error ->
        case Map.get(state.settled, key) do
          %{owner_id: ^owner, handle: stored, result: result} ->
            if stored.incarnation == handle.incarnation,
              do: {:reply, result, state},
              else:
                {:reply, {:error, Error.new(:resource_conflict, "stale resource incarnation")},
                 state}

          _ ->
            {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:cancel_owner, owner}, from, state) do
    keys =
      all_entries(state)
      |> Enum.filter(fn {_key, entry} -> entry.owner_id == owner end)
      |> Enum.map(&elem(&1, 0))

    if keys == [] do
      {:reply, {:ok, []}, state}
    else
      state = Enum.reduce(keys, state, fn key, acc -> request_cleanup(acc, key, nil) end)

      task =
        Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
          Enum.map(keys, fn key ->
            GenServer.call(self_registry(state), {:release_key, key}, :infinity)
          end)
        end)

      # The coordinating task waits outside the registry. Each release call is
      # completed by a separate cleanup task, so registry requests stay live.
      {:noreply, %{state | tasks: Map.put(state.tasks, task.ref, {:coordinator, from})}}
    end
  end

  def handle_call({:release_key, key}, from, state),
    do: {:noreply, request_cleanup(state, key, from)}

  @impl true
  def handle_info({ref, results}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(tasks, ref) do
      {{:coordinator, from}, rest} ->
        GenServer.reply(from, {:ok, results})
        {:noreply, %{state | tasks: rest}}

      {{:cleanup, key}, rest} ->
        {:noreply, settle_cleanup(%{state | tasks: rest}, key, results)}
    end
  end

  def handle_info({:cleanup_timeout, ref}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    case Map.get(tasks, ref) do
      {:cleanup, key} ->
        Process.exit(task_pid(state, key), :kill)
        Process.demonitor(ref, [:flush])
        next = %{state | tasks: Map.delete(tasks, ref)}
        {:noreply, settle_cleanup(next, key, {:uncertain, :cleanup_timeout})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    case Map.pop(tasks, ref) do
      {{:cleanup, key}, rest} ->
        {:noreply, settle_cleanup(%{state | tasks: rest}, key, {:uncertain, {:exit, reason}})}

      {{:coordinator, from}, rest} ->
        GenServer.reply(
          from,
          {:error,
           Error.new(:unknown_outcome, "owner cleanup coordinator stopped", cause: reason)}
        )

        {:noreply, %{state | tasks: rest}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    next =
      Enum.reduce(all_entries(state), state, fn {key, entry}, acc ->
        if entry.monitor_ref == ref, do: request_cleanup(acc, key, nil), else: acc
      end)

    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp self_registry(state), do: state.registry_pid

  defp entry(handle, value, cleanup, owner_pid) do
    %{
      handle: handle,
      owner_id: handle.owner_id,
      value: value,
      cleanup: cleanup,
      monitor_ref: if(is_pid(owner_pid), do: Process.monitor(owner_pid)),
      status: :active,
      reason: nil,
      task: nil,
      timer: nil,
      waiters: []
    }
  end

  defp all_entries(state),
    do:
      Enum.map(state.resources, fn {id, entry} -> {{:resource, id}, entry} end) ++
        Enum.map(state.sessions, fn {id, entry} -> {{:session, id}, entry} end)

  defp get_entry(state, {:resource, id}), do: Map.get(state.resources, id)
  defp get_entry(state, {:session, id}), do: Map.get(state.sessions, id)

  defp put_entry(state, {:resource, id}, entry),
    do: %{state | resources: Map.put(state.resources, id, entry)}

  defp put_entry(state, {:session, id}, entry),
    do: %{state | sessions: Map.put(state.sessions, id, entry)}

  defp request_cleanup(state, key, from) do
    case get_entry(state, key) do
      nil ->
        if from, do: GenServer.reply(from, {:ok, :already_released})
        state

      %{status: :active, cleanup: nil} = entry ->
        if from, do: GenServer.reply(from, {:ok, :not_requested})
        remove_entry(state, key, entry, :confirmed, {:ok, :not_requested})

      %{status: :active} = entry ->
        task =
          Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
            safe_cleanup(entry.cleanup)
          end)

        timer = Process.send_after(self(), {:cleanup_timeout, task.ref}, state.cleanup_timeout)

        next = %{
          entry
          | status: :in_progress,
            task: task,
            timer: timer,
            waiters: if(from, do: [from], else: [])
        }

        state
        |> put_entry(key, next)
        |> Map.update!(:tasks, &Map.put(&1, task.ref, {:cleanup, key}))

      %{status: :in_progress} = entry ->
        put_entry(state, key, %{
          entry
          | waiters: if(from, do: [from | entry.waiters], else: entry.waiters)
        })

      entry ->
        if from,
          do:
            GenServer.reply(
              from,
              {:error,
               Error.new(:unknown_outcome, "resource cleanup needs reconciliation",
                 details: %{status: entry.status, reason: entry.reason}
               )}
            )

        state
    end
  end

  defp settle_cleanup(state, key, result) do
    case get_entry(state, key) do
      nil ->
        state

      entry ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        {status, reason, reply} = normalize_cleanup(result)
        Enum.each(entry.waiters, &GenServer.reply(&1, reply))
        next = %{entry | status: status, reason: reason, task: nil, timer: nil, waiters: []}

        if status == :confirmed,
          do: remove_entry(state, key, next, status, reply),
          else: put_entry(state, key, next)
    end
  end

  defp normalize_cleanup({:ok, value}), do: {:confirmed, nil, {:ok, value}}

  defp normalize_cleanup({:error, reason}),
    do:
      {:failed, reason,
       {:error, Error.new(:unknown_outcome, "resource cleanup failed", cause: reason)}}

  defp normalize_cleanup({:uncertain, reason}),
    do:
      {:uncertain, reason,
       {:error, Error.new(:unknown_outcome, "resource cleanup is unconfirmed", cause: reason)}}

  defp safe_cleanup(fun) do
    try do
      case fun.() do
        {:error, reason} -> {:error, reason}
        {:uncertain, reason} -> {:uncertain, reason}
        :ok -> {:ok, :ok}
        :done -> {:ok, :done}
        {:ok, status} when status in [:confirmed, :released, :done] -> {:ok, status}
        value -> {:uncertain, {:unconfirmed_cleanup_reply, inspect(value)}}
      end
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp task_pid(state, key), do: get_entry(state, key).task.pid

  defp remove_entry(state, key, entry, status, result \\ {:ok, :released}) do
    if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])

    settled =
      Map.put(state.settled, key, %{
        owner_id: entry.owner_id,
        handle: entry.handle,
        status: status,
        reason: nil,
        result: result
      })

    order = :queue.in(key, state.settled_order)

    {settled, order} =
      if map_size(settled) > @max_settled do
        {{:value, oldest}, rest} = :queue.out(order)
        {Map.delete(settled, oldest), rest}
      else
        {settled, order}
      end

    case key do
      {:resource, id} ->
        %{
          state
          | resources: Map.delete(state.resources, id),
            settled: settled,
            settled_order: order
        }

      {:session, id} ->
        %{
          state
          | sessions: Map.delete(state.sessions, id),
            settled: settled,
            settled_order: order
        }
    end
  end

  defp lookup_resource(state, %{resource_id: id} = handle, owner)
       when is_binary(id) and is_binary(owner) do
    case Map.get(state.resources, id) do
      %{owner_id: actual, handle: stored} = entry ->
        cond do
          actual != owner ->
            {:error, Error.new(:forbidden, "resource owner does not match")}

          handle[:incarnation] != stored.incarnation ->
            {:error, Error.new(:resource_conflict, "stale resource incarnation")}

          true ->
            {:ok, entry}
        end

      nil ->
        {:error, Error.new(:not_found, "resource handle is unknown")}
    end
  end

  defp lookup_resource(_, _, _), do: {:error, Error.new(:validation, "invalid resource handle")}

  defp lookup_session(state, id, owner, incarnation)
       when is_integer(id) and is_binary(owner) and
              (is_nil(incarnation) or is_integer(incarnation)) do
    case Map.get(state.sessions, id) do
      %{owner_id: ^owner, handle: stored} = entry ->
        if is_nil(incarnation) or stored.incarnation == incarnation,
          do: {:ok, entry},
          else: {:error, Error.new(:resource_conflict, "stale command session incarnation")}

      %{owner_id: _} ->
        {:error, Error.new(:forbidden, "session owner does not match")}

      nil ->
        {:error, Error.new(:not_found, "command session is unknown")}
    end
  end

  defp lookup_session(_, _, _, _), do: {:error, Error.new(:validation, "invalid command session")}

  defp active(%{status: :active}), do: :ok

  defp active(entry),
    do:
      {:error,
       Error.new(:resource_conflict, "resource cleanup is in progress or needs reconciliation",
         details: %{status: entry.status}
       )}

  defp validate_incarnation(n) when is_integer(n) and n > 0, do: :ok

  defp validate_incarnation(_),
    do: {:error, Error.new(:validation, "incarnation must be positive")}

  defp validate_cleanup(nil), do: :ok
  defp validate_cleanup(fun) when is_function(fun, 0), do: :ok

  defp validate_cleanup(_),
    do: {:error, Error.new(:validation, "cleanup must be a zero-arity function")}
end
