defmodule Backplane.McpProtocol.Client.ResourceRetirement do
  @moduledoc false

  alias Backplane.McpProtocol.Client.{OwnedRequest, RequestCleanup, ResourceRequest}
  alias Backplane.McpProtocol.MCP.Error

  @limit 256
  @obligation_limit 256

  def prepare(%ResourceRequest{} = handle, opts, timeout) do
    if Keyword.get(opts, :track_retirement, false) == true do
      supplied = Keyword.get(opts, :retirement_deadline)

      if is_nil(supplied) or is_integer(supplied) do
        deadline = min(supplied || now() + timeout, now() + timeout)
        {:ok, %{handle | retirement_deadline: deadline}, deadline}
      else
        {:error, Error.protocol(:invalid_params, %{field: "retirement_deadline"})}
      end
    else
      {:ok, handle, nil}
    end
  end

  def prepare(handle, _opts, _timeout), do: {:ok, handle, nil}

  def admission(state, %ResourceRequest{retirement_deadline: deadline})
      when is_integer(deadline) do
    cond do
      deadline <= now() ->
        {:error, Error.transport(:resource_retirement_unavailable)}

      map_size(state.resource_retirements) >= @limit ->
        {:error, Error.transport(:resource_retirement_capacity)}

      true ->
        :ok
    end
  end

  def admission(_state, _handle), do: :ok

  def enroll(state, %ResourceRequest{retirement_deadline: deadline} = handle)
      when is_integer(deadline) do
    entry = %{
      handle: handle,
      deadline: deadline,
      monitor: Process.monitor(handle.owner),
      timer:
        Process.send_after(
          self(),
          {:resource_retirement_expired, handle.logical_id},
          max(deadline - now(), 0)
        ),
      terminal: nil,
      available: true,
      obligations: [],
      cleanup: nil
    }

    put_in(state.resource_retirements[handle.logical_id], entry)
  end

  def enroll(state, _handle), do: state

  # Snapshot before any task reference or wire ID can be replaced by MRTR.
  def capture(state, request) do
    update(state, request.logical_id, fn entry ->
      workers = workers(request)
      obligation = Map.put(request, :retirement_workers, workers)

      obligations =
        case Enum.find_index(entry.obligations, &(&1.id == request.id)) do
          nil ->
            entry.obligations ++ [obligation]

          index ->
            List.update_at(entry.obligations, index, fn old ->
              Map.put(
                obligation,
                :retirement_workers,
                Enum.uniq(old.retirement_workers ++ workers)
              )
            end)
        end

      %{entry | obligations: obligations}
    end)
  end

  def terminal(state, request, kind \\ :completed) do
    state = capture(state, request)
    state = update(state, request.logical_id, &%{&1 | terminal: kind})

    case state.resource_retirements[request.logical_id] do
      %{available: false} ->
        send(self(), {:resource_retirement_expired, request.logical_id})

      %{deadline: deadline} ->
        if deadline <= now(), do: send(self(), {:resource_retirement_expired, request.logical_id})

      nil ->
        :ok
    end

    state
  end

  def continuation_admission(state, request) do
    case state.resource_retirements[request.logical_id] do
      %{obligations: obligations} when length(obligations) >= @obligation_limit ->
        {:error, Error.transport(:resource_retirement_obligation_capacity)}

      _ ->
        :ok
    end
  end

  def mark(state, request, kind), do: update(state, request.logical_id, &%{&1 | terminal: kind})

  def request(handle, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = Keyword.get(opts, :deadline)

    cond do
      not OwnedRequest.owned_by?(handle, self()) ->
        {:error, Error.transport(:request_owner_mismatch)}

      not (is_integer(timeout) and timeout > 0 and timeout <= 2_147_483_647) ->
        {:error, Error.protocol(:invalid_params, %{field: "timeout"})}

      not (is_nil(deadline) or is_integer(deadline)) ->
        {:error, Error.protocol(:invalid_params, %{field: "deadline"})}

      true ->
        due = min(deadline || now() + timeout, now() + timeout)
        due = min(handle.retirement_deadline || due, due)

        GenServer.call(
          handle.client,
          {:retire_resource_request, handle, due},
          max(due - now(), 1) + 100
        )
    end
  catch
    :exit, _ -> {:error, Error.transport(:resource_retirement_unavailable)}
  end

  def retire(state, handle, caller, due, from) do
    entry = state.resource_retirements[handle.logical_id]

    cond do
      handle.owner != caller ->
        {:reply, {:error, Error.transport(:request_owner_mismatch)}, state}

      is_nil(entry) or entry.handle != handle or handle.client != self() ->
        unavailable(state)

      not entry.available or entry.deadline <= now() or due <= now() ->
        unavailable(state)

      is_nil(entry.terminal) ->
        {:reply, {:error, Error.transport(:request_not_terminal)}, state}

      entry.cleanup != nil ->
        unavailable(state)

      true ->
        state = update(state, handle.logical_id, &%{&1 | available: false})
        {:noreply, cleanup(state, handle.logical_id, min(due, entry.deadline), from)}
    end
  end

  def expired(state, id) do
    state = update(state, id, &%{&1 | available: false})

    case state.resource_retirements[id] do
      %{terminal: nil} -> state
      _ -> cleanup(state, id, now() + 1_000, nil)
    end
  end

  def owner_down(state, monitor) do
    case Enum.find(state.resource_retirements, fn {_id, entry} -> entry.monitor == monitor end) do
      {id, _} -> {true, expired(state, id)}
      nil -> {false, state}
    end
  end

  def finish(state, id, token, report, from) do
    case state.resource_retirements[id] do
      %{cleanup: %{token: ^token} = cleanup} = entry ->
        Process.cancel_timer(cleanup.timer)
        Process.demonitor(cleanup.monitor, [:flush])
        # Proof accepted by the Client, not merely produced by the collector,
        # must still be inside the original query's absolute budget.
        report =
          if now() < cleanup.deadline and entry.terminal != nil,
            do: report,
            else: %{report | local_cleanup: :uncertain}

        state =
          if report.local_cleanup == :confirmed do
            forget(state, id, entry)
          else
            update(state, id, &%{&1 | cleanup: nil})
          end

        if from, do: GenServer.reply(from, {:ok, report})
        state

      _ ->
        state
    end
  end

  def all_workers(state) do
    Enum.flat_map(state.resource_retirements, fn {_id, entry} ->
      Enum.flat_map(entry.obligations, & &1.retirement_workers) ++
        case entry.cleanup do
          %{pid: pid} -> [pid]
          nil -> []
        end
    end)
  end

  def clear(state) do
    Enum.each(state.resource_retirements, fn {_id, entry} ->
      Process.cancel_timer(entry.timer)
      Process.demonitor(entry.monitor, [:flush])

      if entry.cleanup do
        Process.cancel_timer(entry.cleanup.timer)
        Process.demonitor(entry.cleanup.monitor, [:flush])
      end
    end)

    %{state | resource_retirements: %{}}
  end

  def pin(state, request) do
    if Map.has_key?(state.resource_retirements, request.logical_id) do
      transport_call(state.transport, :pin_request, request.id, request.deadline)
    else
      :ok
    end
  end

  def timeout(state, id, token) do
    case state.resource_retirements[id] do
      %{cleanup: %{token: ^token, pid: pid, from: from}} = entry ->
        Process.exit(pid, :kill)
        finish(state, id, token, report(entry, [], false), from)

      _ ->
        state
    end
  end

  def cleanup_down(state, monitor) do
    case Enum.find(state.resource_retirements, fn {_id, entry} ->
           match?(%{monitor: ^monitor}, entry.cleanup)
         end) do
      {id, entry} ->
        {true,
         finish(state, id, entry.cleanup.token, report(entry, [], false), entry.cleanup.from)}

      nil ->
        {false, state}
    end
  end

  defp cleanup(state, id, deadline, from) do
    case state.resource_retirements[id] do
      %{cleanup: nil} = entry -> start_cleanup(state, id, entry, deadline, from)
      _ -> state
    end
  end

  defp start_cleanup(state, id, entry, deadline, from) do
    client = self()
    transport = state.transport
    token = make_ref()

    case Task.Supervisor.start_child(Backplane.McpProtocol.Client.OperationSupervisor, fn ->
           reports = Enum.map(entry.obligations, &RequestCleanup.release(&1, transport, deadline))

           confirmed =
             now() <= deadline and reports != [] and
               Enum.all?(reports, &(&1.local_cleanup == :confirmed))

           send(
             client,
             {:resource_retirement_result, id, token, report(entry, reports, confirmed), from}
           )
         end) do
      {:ok, pid} ->
        cleanup = %{
          token: token,
          pid: pid,
          from: from,
          deadline: deadline,
          monitor: Process.monitor(pid),
          timer:
            Process.send_after(
              client,
              {:resource_retirement_timeout, id, token},
              max(deadline - now(), 0)
            )
        }

        update(state, id, &%{&1 | cleanup: cleanup})

      {:error, _} ->
        if from,
          do: GenServer.reply(from, {:error, Error.transport(:resource_retirement_unavailable)})

        state
    end
  end

  defp report(entry, reports, confirmed) do
    evidence = %{
      workers_down: reports != [] and Enum.all?(reports, & &1.cleanup_evidence.workers_down),
      worker_count:
        entry.obligations |> Enum.flat_map(& &1.retirement_workers) |> Enum.uniq() |> length(),
      transport:
        if(reports != [] and Enum.all?(reports, &(&1.cleanup_evidence.transport == :confirmed)),
          do: :confirmed,
          else: :uncertain
        )
    }

    Map.merge(entry.handle.identity, %{
      schema: :resource_retirement,
      version: 1,
      local: :retired,
      request_ids: Enum.map(entry.obligations, & &1.id),
      terminal: entry.terminal || :unavailable,
      local_cleanup: if(confirmed, do: :confirmed, else: :uncertain),
      cleanup_evidence: evidence,
      remote: :unknown
    })
  end

  defp forget(state, id, entry) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.monitor, [:flush])

    Enum.each(
      entry.obligations,
      &transport_call(state.transport, :unpin_request, &1.id, entry.cleanup.deadline)
    )

    %{state | resource_retirements: Map.delete(state.resource_retirements, id)}
  end

  defp transport_call(%{layer: layer, name: name}, function, id, deadline) do
    if function_exported?(layer, function, 3),
      do:
        apply(layer, function, [name, id, [timeout: max(deadline - now(), 1), deadline: deadline]]),
      else: :ok
  catch
    :exit, _ -> {:error, :request_cleanup_unavailable}
  end

  defp workers(request) do
    tasks = for %Task{pid: pid} <- [request.dispatch_task, request.resolver_task], do: pid
    Enum.uniq(tasks ++ List.wrap(request.resolver_supervisor))
  end

  defp update(state, id, fun) do
    case state.resource_retirements[id] do
      nil -> state
      entry -> put_in(state.resource_retirements[id], fun.(entry))
    end
  end

  defp unavailable(state),
    do: {:reply, {:error, Error.transport(:resource_retirement_unavailable)}, state}

  defp now, do: System.monotonic_time(:millisecond)
end
