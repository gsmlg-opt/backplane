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

  def owner_transfer_ready(pid, owner) do
    entries = GenServer.call(pid, {:transfer_entries, owner})

    ready =
      Enum.all?(entries, fn entry ->
        if entry.status != :active do
          false
        else
          case entry.handle do
            %{kind: :continuation} ->
              try do
                Backplane.AgentRuntime.Codex.CodeMode.Worker.ready_for_detach(entry.value) == true
              catch
                :exit, _ -> false
              end

            _ ->
              true
          end
        end
      end)

    if ready,
      do: :ok,
      else: {:error, Error.new(:unknown_outcome, "session resource is not ready for transfer")}
  end

  def owner_status(pid, owner), do: GenServer.call(pid, {:owner_status, owner})

  @doc "Inspect live or recently settled session cleanup, including bounded receipt acknowledgement."
  def session_cleanup_status(pid, session_id, owner, incarnation),
    do: GenServer.call(pid, {:session_cleanup_status, session_id, owner, incarnation})

  def fence_owner(pid, owner), do: GenServer.call(pid, {:fence_owner, owner})
  def close_owner(pid, owner), do: GenServer.call(pid, {:close_owner, owner}, :infinity)

  def code_state(pid, owner, incarnation \\ 1),
    do: GenServer.call(pid, {:code_state, owner, incarnation})

  def store_code_state(pid, handle, owner, key, value),
    do: GenServer.call(pid, {:store_code_state, handle, owner, key, value})

  def worker_supervisor(pid), do: GenServer.call(pid, :worker_supervisor)

  def register_session(pid, owner, value, opts \\ []),
    do: GenServer.call(pid, {:register_session, owner, value, opts})

  def fetch_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:fetch_session, session_id, owner, incarnation})

  def update_session(pid, session_id, owner, value, incarnation \\ nil),
    do: GenServer.call(pid, {:update_session, session_id, owner, value, incarnation})

  def forget_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:forget_session, session_id, owner, incarnation})

  @doc """
  Withdraw an unused reservation after trusted backend evidence proves non-start.

  The caller must verify that later launch attempts have been fenced. A missing
  job binding alone is insufficient evidence; ambiguous launches use release.
  """
  def withdraw_session(pid, session_id, owner, incarnation),
    do: GenServer.call(pid, {:withdraw_session, session_id, owner, incarnation})

  def release_session(pid, session_id, owner, incarnation \\ nil),
    do: GenServer.call(pid, {:release_session, session_id, owner, incarnation}, :infinity)

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :cleanup_timeout, @default_cleanup_timeout)
    max_continuations = Keyword.get(opts, :max_continuations, 16)

    if is_integer(timeout) and timeout > 0 and timeout <= 60_000 and is_integer(max_continuations) and
         max_continuations in 1..256 do
      {:ok, cleanup_supervisor} = Task.Supervisor.start_link()
      {:ok, worker_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

      {:ok,
       %{
         max_continuations: max_continuations,
         code_state: %{},
         code_owner_monitors: %{},
         closed_owners: MapSet.new(),
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
      {:stop,
       Error.new(
         :validation,
         "cleanup_timeout must be 1..60000 ms and max_continuations must be 1..256"
       )}
    end
  end

  @impl true
  def handle_call({:code_state, owner, incarnation}, _from, state) do
    with :ok <- owner_open(state, owner), :ok <- validate_incarnation(incarnation) do
      {:reply, Map.get(state.code_state, {owner, incarnation}, %{}), state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:store_code_state, handle, owner, key, value}, _from, state) do
    with :ok <- owner_open(state, owner),
         {:ok, entry} <- lookup_resource(state, handle, owner),
         :ok <- active(entry) do
      identity = {owner, handle.incarnation}
      stored = Map.put(Map.get(state.code_state, identity, %{}), key, value)
      all_stored = Map.put(state.code_state, identity, stored)

      if map_size(stored) <= 256 and :erlang.external_size(stored) <= 1_048_576 and
           map_size(all_stored) <= 64 and :erlang.external_size(all_stored) <= 16_777_216 do
        state = monitor_code_owner(state, owner, entry.owner_pid)
        {:reply, :ok, %{state | code_state: all_stored}}
      else
        {:reply,
         {:error, Error.new(:budget_exceeded, "Code Mode stored state exceeds its bound")}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:fence_owner, owner}, _from, state),
    do:
      {:reply, :ok,
       %{clear_code_state(state, owner) | closed_owners: MapSet.put(state.closed_owners, owner)}}

  def handle_call({:close_owner, owner}, from, state) do
    handle_call({:cancel_owner, owner}, from, %{
      state
      | closed_owners: MapSet.put(state.closed_owners, owner)
    })
  end

  def handle_call(:worker_supervisor, _from, state),
    do: {:reply, {:ok, state.worker_supervisor}, state}

  def handle_call({:register, owner, kind, value, opts}, _from, state)
      when is_binary(owner) and owner != "" and is_atom(kind) do
    incarnation = Keyword.get(opts, :incarnation, 1)
    cleanup = Keyword.get(opts, :cleanup)

    with :ok <- owner_open(state, owner),
         :ok <- resource_capacity(state, kind),
         :ok <- validate_incarnation(incarnation),
         :ok <- validate_cleanup(cleanup) do
      id = "res_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      handle = %{resource_id: id, owner_id: owner, incarnation: incarnation, kind: kind}

      entry =
        entry(handle, value, normalize_cleanup(cleanup, handle), Keyword.get(opts, :owner_pid))

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

  def handle_call({:transfer_entries, owner}, _from, state),
    do:
      {:reply,
       all_entries(state) |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(&1.owner_id == owner)),
       state}

  def handle_call({:owner_status, owner}, _from, state) do
    statuses =
      all_entries(state)
      |> Enum.filter(fn {_key, entry} -> entry.owner_id == owner end)
      |> Enum.map(fn {key, entry} ->
        %{id: elem(key, 1), kind: elem(key, 0), status: entry.status, reason: entry.reason}
      end)

    {:reply, {:ok, statuses}, state}
  end

  def handle_call({:session_cleanup_status, id, owner, incarnation}, _from, state) do
    case lookup_session(state, id, owner, incarnation) do
      {:ok, entry} ->
        {:reply, {:ok, Map.take(entry, [:status, :reason])}, state}

      {:error, %Error{class: :not_found}} = error ->
        case Map.get(state.settled, {:session, id}) do
          %{owner_id: ^owner, handle: %{incarnation: ^incarnation}} = receipt ->
            {:reply, {:ok, Map.take(receipt, [:status, :reason, :acknowledgement])}, state}

          _ ->
            {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:register_session, owner, value, opts}, _from, state)
      when is_binary(owner) and owner != "" and is_list(opts) do
    cleanup = Keyword.get(opts, :cleanup)

    with :ok <- owner_open(state, owner),
         :ok <- validate_cleanup(cleanup),
         :ok <- validate_lifecycle(Keyword.get(opts, :acknowledge)),
         :ok <- validate_incarnation(Keyword.get(opts, :incarnation, 1)) do
      id = System.unique_integer([:positive, :monotonic])
      handle = %{session_id: id, owner_id: owner, incarnation: Keyword.get(opts, :incarnation, 1)}

      entry =
        entry(handle, value, normalize_cleanup(cleanup, handle), Keyword.get(opts, :owner_pid))
        |> Map.put(:acknowledge, Keyword.get(opts, :acknowledge))

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

  def handle_call({:withdraw_session, id, owner, incarnation}, _from, state) do
    with {:ok, entry} <- lookup_session(state, id, owner, incarnation),
         :ok <- active(entry),
         true <- match?(%{job: nil}, entry.value) do
      {:reply, :ok,
       remove_entry(state, {:session, id}, Map.put(entry, :acknowledge, nil), :confirmed)}
    else
      false ->
        {:reply,
         {:error,
          Error.new(:resource_conflict, "only an unused command reservation can be withdrawn")},
         state}

      error ->
        {:reply, error, state}
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
    state = clear_code_state(state, owner)

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
  def handle_info({:acknowledge_timeout, ref, pid}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    case Map.pop(tasks, ref) do
      {{:acknowledge, key, _timer}, rest} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        {:noreply,
         settle_acknowledgement(%{state | tasks: rest}, key, {:error, :acknowledgement_timeout})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, results}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(tasks, ref) do
      {{:coordinator, from}, rest} ->
        GenServer.reply(from, {:ok, results})
        {:noreply, %{state | tasks: rest}}

      {{:cleanup, key}, rest} ->
        {:noreply, settle_cleanup(%{state | tasks: rest}, key, results)}

      {{:acknowledge, key, timer}, rest} ->
        Process.cancel_timer(timer)
        {:noreply, settle_acknowledgement(%{state | tasks: rest}, key, results)}
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

      {{:acknowledge, key, timer}, rest} ->
        Process.cancel_timer(timer)
        {:noreply, settle_acknowledgement(%{state | tasks: rest}, key, {:error, reason})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    owner =
      Enum.find_value(state.code_owner_monitors, fn {owner, monitor} ->
        if monitor.ref == ref, do: owner
      end)

    state =
      if owner do
        state = clear_code_state(state, owner)
        state = %{state | closed_owners: MapSet.put(state.closed_owners, owner)}

        Enum.reduce(all_entries(state), state, fn {key, entry}, acc ->
          if entry.owner_id == owner, do: request_cleanup(acc, key, nil), else: acc
        end)
      else
        state
      end

    next =
      Enum.reduce(all_entries(state), state, fn {key, entry}, acc ->
        if entry.monitor_ref == ref do
          acc = clear_code_state(acc, entry.owner_id)
          acc = %{acc | closed_owners: MapSet.put(acc.closed_owners, entry.owner_id)}
          request_cleanup(acc, key, nil)
        else
          acc
        end
      end)

    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp resource_capacity(state, :continuation) do
    count = Enum.count(state.resources, fn {_, entry} -> entry.handle.kind == :continuation end)

    if count < state.max_continuations,
      do: :ok,
      else: {:error, Error.new(:overloaded, "Code Mode cell capacity reached")}
  end

  defp resource_capacity(_state, _kind), do: :ok

  defp owner_open(state, owner) do
    if MapSet.member?(state.closed_owners, owner),
      do: {:error, Error.new(:resource_conflict, "resource owner is closed")},
      else: :ok
  end

  defp monitor_code_owner(state, owner, pid) when is_pid(pid) do
    if Map.has_key?(state.code_owner_monitors, owner),
      do: state,
      else: %{
        state
        | code_owner_monitors:
            Map.put(state.code_owner_monitors, owner, %{pid: pid, ref: Process.monitor(pid)})
      }
  end

  defp monitor_code_owner(state, _owner, _pid), do: state

  defp clear_code_state(state, owner) do
    case state.code_owner_monitors[owner] do
      %{ref: ref} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    %{
      state
      | code_owner_monitors: Map.delete(state.code_owner_monitors, owner),
        code_state:
          Map.reject(state.code_state, fn {{stored_owner, _}, _} -> stored_owner == owner end)
    }
  end

  defp self_registry(state), do: state.registry_pid

  defp entry(handle, value, cleanup, owner_pid) do
    %{
      handle: handle,
      owner_pid: owner_pid,
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

    state =
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

    case Map.get(entry, :acknowledge) do
      fun when is_function(fun, 1) ->
        task =
          Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
            lifecycle(fun, entry.handle)
          end)

        timer =
          Process.send_after(
            self(),
            {:acknowledge_timeout, task.ref, task.pid},
            state.cleanup_timeout
          )

        %{state | tasks: Map.put(state.tasks, task.ref, {:acknowledge, key, timer})}

      _ ->
        state
    end
  end

  defp settle_acknowledgement(state, key, result) do
    case Map.get(state.settled, key) do
      nil ->
        state

      receipt ->
        %{
          state
          | settled: Map.put(state.settled, key, Map.put(receipt, :acknowledgement, result))
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
  defp validate_cleanup(fun) when is_function(fun, 1), do: :ok

  defp validate_cleanup(_),
    do: {:error, Error.new(:validation, "cleanup must be a zero- or one-arity function")}

  defp validate_lifecycle(nil), do: :ok
  defp validate_lifecycle(fun) when is_function(fun, 1), do: :ok

  defp validate_lifecycle(_),
    do: {:error, Error.new(:validation, "session lifecycle callback must have arity one")}

  defp lifecycle(fun, handle) do
    case fun.(handle) do
      :ok ->
        :ok

      {:error, %Error{}} = error ->
        error

      _ ->
        {:error, Error.new(:unknown_outcome, "session lifecycle acknowledgement is unconfirmed")}
    end
  rescue
    error ->
      {:error,
       Error.new(:unknown_outcome, "session lifecycle callback failed",
         cause: Exception.message(error)
       )}
  catch
    kind, reason ->
      {:error,
       Error.new(:unknown_outcome, "session lifecycle callback stopped", cause: {kind, reason})}
  end

  defp normalize_cleanup(nil, _handle), do: nil
  defp normalize_cleanup(fun, _handle) when is_function(fun, 0), do: fun
  defp normalize_cleanup(fun, handle) when is_function(fun, 1), do: fn -> fun.(handle) end
end
