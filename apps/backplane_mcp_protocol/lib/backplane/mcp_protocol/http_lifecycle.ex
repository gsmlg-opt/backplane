defmodule Backplane.McpProtocol.HTTP.Lifecycle do
  @moduledoc false
  use GenServer

  alias Backplane.McpProtocol.Client.OperationSupervisor
  alias Backplane.McpProtocol.MCP.Error
  alias Elixir.HTTP.RequestCompletion

  @recent_limit 64
  @retry_interval 25

  def start_link(transport, activation_id \\ nil) do
    GenServer.start_link(__MODULE__, {transport, activation_id || make_ref(), self()})
  end

  def start(pid, fun, scope \\ :request), do: GenServer.call(pid, {:start, fun, scope})
  def track(pid, resource), do: GenServer.call(pid, {:track, resource})
  def allocation(pid, job), do: GenServer.call(pid, {:allocation, job})
  def completion(pid, id, handle), do: GenServer.call(pid, {:completion, id, handle})
  def status(pid), do: GenServer.call(pid, :status)

  def close(pid, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    if is_integer(timeout) and timeout > 0 do
      GenServer.call(pid, {:close, timeout, Keyword.get(opts, :activation_id)}, timeout + 100)
    else
      {:error, Error.protocol(:invalid_params, %{reason: :invalid_cleanup_timeout})}
    end
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_report_unavailable)}
  end

  @impl true
  def init({transport, activation, owner}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)

    {:ok,
     %{
       owner: owner,
       orphan: false,
       transport: transport,
       activation: activation,
       jobs: %{},
       monitors: %{},
       live_jobs: 0,
       requests: %{},
       phase: :active,
       report: nil,
       waiters: [],
       deadline: nil,
       timer: nil,
       work: nil,
       results: %{},
       checks: :queue.new(),
       queued: MapSet.new(),
       retries: MapSet.new(),
       retry_timer: nil,
       recent: :queue.new(),
       recent_count: 0,
       confirmed_counts: %{}
     }}
  end

  @impl true
  def handle_call({:start, fun, scope}, _from, %{phase: :active} = state) do
    id = make_ref()
    coordinator = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go ->
            Process.put(:mcp_http_lifecycle, {coordinator, id})
            fun.()
            send(coordinator, {:finished, id})
        end
      end)

    state = add_job(state, id, pid, monitor, scope)
    send(pid, :go)
    {:reply, {:ok, pid}, state}
  end

  def handle_call({:start, _, _}, _from, state), do: {:reply, {:error, :closing}, state}

  def handle_call({:track, pid}, _from, %{phase: :active} = state) do
    state = add_job(state, make_ref(), pid, Process.monitor(pid), :controller)
    {:reply, :ok, state}
  end

  def handle_call({:track, _}, _from, state), do: {:reply, {:error, :closing}, state}

  def handle_call({:allocation, job}, _from, %{phase: :active} = state) do
    id = make_ref()
    request = %{job: job, handle: nil}
    state = put_in(state.requests[id], request)
    state = update_in(state.jobs[job], &%{&1 | requests: MapSet.put(&1.requests, id), had_requests: true})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:allocation, _}, _from, state), do: {:reply, {:error, :closing}, state}

  def handle_call({:completion, id, handle}, _from, state) do
    case Map.fetch(state.requests, id) do
      {:ok, request} ->
        state = put_in(state.requests[id].handle, handle)
        state = if state.jobs[request.job].down, do: enqueue(state, id), else: state
        {:reply, :ok, observe_next(state)}

      :error ->
        {:reply, {:error, :missing_obligation}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, {:ok, report(state)}, state}

  def handle_call({:close, _timeout, _activation}, from, %{phase: :closing} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call({:close, _timeout, _activation}, _from, %{phase: :closed} = state),
    do: {:reply, {:ok, state.report}, state}

  def handle_call({:close, timeout, _activation}, from, state) do
    {:noreply, begin_close(state, timeout, [from])}
  end

  @impl true
  def handle_info({:finished, id}, state) do
    state = if Map.has_key?(state.jobs, id), do: put_in(state.jobs[id].finished, true), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    state = %{state | orphan: true}
    state = if state.phase == :active, do: begin_close(state, 1_000, []), else: state
    continue(state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{work: %{task: %{ref: ref}}} = state) do
    work = state.work
    state = %{state | work: nil}
    continue(work_down(state, work, reason))
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, monitors} ->
        state = %{state | monitors: monitors, live_jobs: state.live_jobs - 1}
        state = update_in(state.jobs[id], &%{&1 | down: true, reason: reason})
        state = Enum.reduce(state.jobs[id].requests, state, &enqueue(&2, &1))
        state = state |> compact_job(id) |> observe_next() |> maybe_cleanup()
        continue(state)
    end
  end

  def handle_info({ref, result}, %{work: %{task: %{ref: ref}}} = state) do
    {:noreply, put_in(state.work.result, result)}
  end

  def handle_info(:retry_checks, state) do
    retries = state.retries
    state = %{state | retries: MapSet.new(), retry_timer: nil}
    state = Enum.reduce(retries, state, &enqueue(&2, &1))
    {:noreply, observe_next(state)}
  end

  def handle_info({:resource_result, resource}, %{phase: :closing} = state) do
    {:noreply, put_in(state.results[resource.id], resource)}
  end

  def handle_info(:close_deadline, %{phase: :closing} = state) do
    kill_work(state)
    resources = pending_resources(state) ++ work_resource(state, {:error, :cleanup_worker_pending})
    continue(finish(state, resources))
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_work(state)
    Enum.each(state.jobs, fn {_id, job} -> if not job.down, do: Process.exit(job.pid, :kill) end)

    # OTP handles a linked parent's EXIT before the ordinary owner-DOWN clause.
    # Transfer unresolved cleanup to one supervised, deadline-bounded queue.
    if state.phase != :closed and map_size(state.requests) > 0 do
      deadline = state.deadline || System.monotonic_time(:millisecond) + 1_000
      requests = state.requests

      Task.Supervisor.start_child(OperationSupervisor, fn ->
        Enum.each(requests, fn {_id, request} ->
          if request.handle, do: RequestCompletion.abort_and_await(request.handle, remaining(deadline))
        end)
      end)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp add_job(state, id, pid, monitor, scope) do
    job = %{
      pid: pid,
      monitor: monitor,
      finished: false,
      down: false,
      reason: nil,
      scope: scope,
      requests: MapSet.new(),
      had_requests: false
    }

    %{
      state
      | jobs: Map.put(state.jobs, id, job),
        monitors: Map.put(state.monitors, monitor, id),
        live_jobs: state.live_jobs + 1
    }
  end

  defp enqueue(%{phase: :active} = state, id) do
    request = state.requests[id]
    observing = match?(%{kind: {:observe, ^id}}, state.work)

    if request && request.handle && not observing && not MapSet.member?(state.queued, id) do
      %{state | checks: :queue.in(id, state.checks), queued: MapSet.put(state.queued, id)}
    else
      state
    end
  end

  defp enqueue(state, _id), do: state

  defp observe_next(%{phase: :active, work: nil} = state) do
    case :queue.out(state.checks) do
      {:empty, _} ->
        state

      {{:value, id}, checks} ->
        state = %{state | checks: checks, queued: MapSet.delete(state.queued, id)}
        handle = state.requests[id].handle

        case start_work(state, {:observe, id}, fn -> RequestCompletion.await(handle, 0) end) do
          {:ok, state} -> state
          {:error, state} -> observe_next(state)
        end
    end
  end

  defp observe_next(state), do: state

  defp work_down(%{phase: :active} = state, %{kind: {:observe, id}, result: result}, _reason) do
    state =
      case result do
        :ok -> compact_request(state, id)
        {:error, :cleanup_pending} -> retry_later(state, id)
        _ -> state
      end

    observe_next(state)
  end

  defp work_down(%{phase: :closing} = state, %{kind: :close, result: :done} = work, :normal) do
    resources = pending_resources(state) ++ [resource(state, work.task.ref, :http_worker, :ok)]
    finish(state, resources)
  end

  defp work_down(%{phase: :closing} = state, %{kind: :close} = work, _reason) do
    resources =
      pending_resources(state) ++
        [resource(state, work.task.ref, :http_worker, {:error, :cleanup_worker_evidence_lost})]

    finish(state, resources)
  end

  defp work_down(%{phase: :closing} = state, _work, _reason), do: maybe_cleanup(state)
  defp work_down(state, _work, _reason), do: state

  defp retry_later(state, id) do
    timer = state.retry_timer || Process.send_after(self(), :retry_checks, @retry_interval)
    %{state | retries: MapSet.put(state.retries, id), retry_timer: timer}
  end

  defp compact_request(state, id) do
    request = state.requests[id]
    job = state.jobs[request.job]

    # Only the original RequestCompletion barrier AND actual owned worker DOWN
    # authorize replacing this handle with confirmed historical evidence.
    if job.down do
      state = remember(state, resource(state, id, :http_request, :ok))
      state = %{state | requests: Map.delete(state.requests, id), retries: MapSet.delete(state.retries, id)}
      state = update_in(state.jobs[request.job].requests, &MapSet.delete(&1, id))
      compact_job(state, request.job)
    else
      state
    end
  end

  defp compact_job(state, id) do
    job = state.jobs[id]

    if job.down and MapSet.size(job.requests) == 0 and worker_confirmed?(job) do
      state = remember(state, worker_resource(state, id, job))
      %{state | jobs: Map.delete(state.jobs, id)}
    else
      state
    end
  end

  defp remember(state, resource) do
    recent = :queue.in(resource, state.recent)

    if state.recent_count < @recent_limit do
      %{state | recent: recent, recent_count: state.recent_count + 1}
    else
      {{:value, oldest}, recent} = :queue.out(recent)
      counts = Map.update(state.confirmed_counts, oldest.scope, 1, &(&1 + 1))
      %{state | recent: recent, confirmed_counts: counts}
    end
  end

  defp begin_close(state, timeout, waiters) do
    deadline = System.monotonic_time(:millisecond) + timeout
    Enum.each(state.jobs, fn {_id, job} -> if not job.down, do: Process.exit(job.pid, :kill) end)
    kill_work(state)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)

    state = %{
      state
      | phase: :closing,
        deadline: deadline,
        timer: Process.send_after(self(), :close_deadline, timeout),
        waiters: waiters,
        checks: :queue.new(),
        queued: MapSet.new(),
        retries: MapSet.new(),
        retry_timer: nil,
        report: %{base_report(state) | close_id: make_ref(), phase: :closing}
    }

    maybe_cleanup(state)
  end

  defp maybe_cleanup(%{phase: :closing, work: nil, live_jobs: 0} = state) do
    if map_size(state.requests) == 0 do
      finish(state, pending_resources(state))
    else
      coordinator = self()
      requests = state.requests
      deadline = state.deadline
      activation = state.activation

      work = fn ->
        Enum.each(requests, fn {id, request} ->
          result =
            if request.handle,
              do: RequestCompletion.abort_and_await(request.handle, remaining(deadline)),
              else: {:error, :missing_completion_handle}

          send(coordinator, {:resource_result, resource(%{activation: activation}, id, :http_request, result)})
        end)

        :done
      end

      case start_work(state, :close, work) do
        {:ok, state} ->
          state

        {:error, state} ->
          finish(
            state,
            pending_resources(state) ++
              [resource(state, :cleanup_worker, :http_worker, {:error, :cleanup_worker_unavailable})]
          )
      end
    end
  end

  defp maybe_cleanup(state), do: state

  defp start_work(state, kind, fun) do
    task = Task.Supervisor.async_nolink(OperationSupervisor, fun)
    {:ok, %{state | work: %{task: task, kind: kind, result: nil}}}
  catch
    :exit, _ -> {:error, state}
  end

  defp kill_work(%{work: %{task: task}}), do: Process.exit(task.pid, :kill)
  defp kill_work(_state), do: :ok

  defp continue(%{orphan: true, phase: :closed} = state), do: {:stop, :normal, state}
  defp continue(state), do: {:noreply, state}

  defp finish(state, resources) do
    if state.timer, do: Process.cancel_timer(state.timer)
    outcome = if Enum.all?(resources, &(&1.outcome == :confirmed)), do: :confirmed, else: :unconfirmed
    report = %{state.report | activation_id: state.activation, phase: :closed, outcome: outcome, resources: resources}
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, report}))
    %{state | phase: :closed, report: report, waiters: []}
  end

  defp pending_resources(state) do
    Enum.map(state.requests, fn {id, _} ->
      Map.get(state.results, {state.activation, id}, resource(state, id, :http_request, {:error, :cleanup_pending}))
    end) ++ worker_resources(state) ++ confirmed_resources(state)
  end

  defp worker_resources(state), do: Enum.map(state.jobs, fn {id, job} -> worker_resource(state, id, job) end)

  defp worker_resource(state, id, job) do
    result = if worker_confirmed?(job), do: :ok, else: {:error, :worker_evidence_lost}
    resource(state, id, if(job.scope == :controller, do: :stream_controller, else: :http_worker), result)
  end

  defp worker_confirmed?(job),
    do: job.down and (job.finished or job.had_requests or job.scope in [:consumer, :controller])

  defp work_resource(%{work: %{task: task}} = state, result), do: [resource(state, task.ref, :http_worker, result)]

  defp work_resource(_state, _result), do: []

  defp confirmed_resources(state) do
    aggregates =
      Enum.map(state.confirmed_counts, fn {scope, count} ->
        resource = resource(state, "confirmed_history:#{scope}", scope, :ok)
        %{resource | evidence: Map.merge(resource.evidence, %{aggregate: true, confirmed_count: count})}
      end)

    aggregates ++ :queue.to_list(state.recent)
  end

  defp resource(state, id, scope, result) do
    %{
      id: {state.activation, id},
      scope: scope,
      outcome: if(result == :ok, do: :confirmed, else: :uncertain),
      evidence: %{barrier: if(scope == :http_request, do: :request_completion, else: :process_down), result: result},
      error: if(result == :ok, do: nil, else: result)
    }
  end

  defp report(%{report: nil} = state), do: base_report(state)
  defp report(state), do: state.report

  defp base_report(state) do
    %{
      version: 1,
      close_id: nil,
      activation_id: state.activation,
      transport: state.transport,
      phase: state.phase,
      outcome: :pending,
      resources: confirmed_resources(state),
      remote: %{outcome: :unknown, session_delete: nil}
    }
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
