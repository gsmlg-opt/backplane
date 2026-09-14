defmodule Backplane.AgentRuntime.ExecutionController do
  use GenServer

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Execution
  alias Backplane.AgentRuntime.Kernel

  @moduledoc """
  One-run control owner that keeps store and backend work outside callbacks.

  Cancellation can race a pending intent commit. Whichever transition commits
  first fences the other by revision; an intent acknowledgement observed after
  cancellation never restores dispatch authority.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec submit(GenServer.server(), map()) :: {:ok, map()} | {:error, Error.t()}
  def submit(server, meta), do: GenServer.call(server, {:submit, meta})

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @spec cancel(GenServer.server(), non_neg_integer()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(server, at), do: GenServer.call(server, {:cancel, at})

  @spec settle_cleanup(GenServer.server(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def settle_cleanup(server, at, settlement),
    do: GenServer.call(server, {:settle_cleanup, at, settlement})

  @spec await(GenServer.server(), timeout()) :: term()
  def await(server, timeout \\ 5_000), do: GenServer.call(server, :await, timeout)

  @spec await_run_state(GenServer.server(), atom(), timeout()) :: map()
  def await_run_state(server, run_state, timeout \\ 5_000),
    do: GenServer.call(server, {:await_run_state, run_state}, timeout)

  @impl GenServer
  def init(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       store: Keyword.fetch!(opts, :store),
       context: Keyword.fetch!(opts, :context),
       run: Keyword.fetch!(opts, :run),
       budget: Keyword.get(opts, :budget),
       execution_opts: Keyword.drop(opts, [:store, :context, :run, :name]),
       supervisor: supervisor,
       tasks: %{},
       intent_ref: nil,
       control_ref: nil,
       phase: :idle,
       cancel_requested: nil,
       last_result: nil,
       waiters: [],
       state_waiters: []
     }}
  end

  @impl GenServer
  def handle_call({:submit, meta}, _from, %{phase: :idle, tasks: tasks} = state)
      when map_size(tasks) == 0 and is_map(meta) do
    {state, ref} = start_commit(state, meta, :intent_commit)
    {:reply, {:ok, %{status: :submitted}}, %{state | phase: :committing, intent_ref: ref}}
  end

  def handle_call({:submit, _meta}, _from, state) do
    {:reply, {:error, Error.new(:resource_conflict, "run is not ready for another command")},
     state}
  end

  def handle_call(:status, _from, state) do
    {:reply, status_result(state), state}
  end

  def handle_call({:cancel, at}, _from, state) when is_integer(at) and at >= 0 do
    cond do
      Kernel.terminal?(state.run.state) ->
        {:reply, {:error, Error.new(:resource_conflict, "run is already terminal")}, state}

      state.cancel_requested != nil ->
        {:reply, {:ok, %{status: :accepted}}, state}

      true ->
        state = %{state | cancel_requested: %{at: at}, phase: :cancelling}
        state = maybe_start_cancellation(state)
        {:reply, {:ok, %{status: :accepted}}, state}
    end
  end

  def handle_call({:cancel, _at}, _from, state) do
    {:reply, {:error, Error.new(:validation, "cancellation timestamp is required")}, state}
  end

  def handle_call({:settle_cleanup, at, settlement}, _from, state)
      when is_integer(at) and at >= 0 and is_map(settlement) do
    if state.run.state == :cancelling and is_nil(state.control_ref) do
      meta = %{command: {:cleanup_settled, at, settlement}}
      {state, ref} = start_commit(state, meta, :cleanup_commit)
      {:reply, {:ok, %{status: :submitted}}, %{state | control_ref: ref, phase: :cleanup}}
    else
      {:reply, {:error, Error.new(:resource_conflict, "run is not ready to settle cleanup")},
       state}
    end
  end

  def handle_call(:await, from, state) do
    if map_size(state.tasks) == 0 do
      {:reply, state.last_result, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call({:await_run_state, run_state}, from, state) do
    if state.run.state == run_state do
      {:reply, status_result(state), state}
    else
      {:noreply, %{state | state_waiters: [{from, run_state} | state.state_waiters]}}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{task: task, role: role, data: data}, tasks} ->
        Process.demonitor(task.ref, [:flush])
        state = %{state | tasks: tasks}
        state = handle_task_result(role, result, data, state)
        {:noreply, notify_waiters(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{role: role}, tasks} ->
        error = Error.new(:execution_failure, "execution worker exited", cause: reason)
        state = %{state | tasks: tasks}
        state = handle_task_result(role, {:error, error}, %{}, state)
        {:noreply, notify_waiters(state)}
    end
  end

  defp handle_task_result(:intent_commit, {:ok, committed, prepared}, _data, state) do
    state = %{
      state
      | run: prepared.run,
        budget: prepared.budget,
        intent_ref: nil,
        last_result: {:ok, committed, result(prepared, [])}
    }

    if state.cancel_requested do
      state
      |> Map.put(:phase, :cancelling)
      |> maybe_start_cancellation()
    else
      case prepared.effect do
        :none ->
          %{state | phase: next_phase(prepared.run)}

        _effect ->
          {state, ref} = start_effect(state, committed, prepared)
          %{state | phase: :effect, intent_ref: ref}
      end
    end
  end

  defp handle_task_result(:intent_commit, {:error, %Error{} = error}, _data, state) do
    state = %{state | intent_ref: nil, last_result: {:error, error}}

    if state.cancel_requested,
      do: maybe_start_cancellation(%{state | phase: :cancelling}),
      else: %{state | phase: :idle}
  end

  defp handle_task_result(
         :effect,
         dispatch_result,
         %{committed: committed, prepared: prepared},
         state
       ) do
    state = %{state | intent_ref: nil}

    if state.cancel_requested do
      fenced = %{status: :fenced, result: dispatch_result}

      state = %{
        state
        | phase: :cancelling,
          last_result: {:ok, committed, result(prepared, [], [fenced])}
      }

      maybe_start_cancellation(state)
    else
      case dispatch_result do
        {:ok, effects} ->
          %{state | phase: :idle, last_result: {:ok, committed, result(prepared, effects)}}

        {:error, %Error{} = error} ->
          %{state | phase: :idle, last_result: {:error, error}}
      end
    end
  end

  defp handle_task_result(:cancel_commit, {:ok, committed, prepared}, _data, state) do
    %{
      state
      | run: prepared.run,
        budget: prepared.budget,
        control_ref: nil,
        phase: :cancelling,
        last_result: {:ok, committed, result(prepared, [])}
    }
  end

  defp handle_task_result(:cancel_commit, {:error, %Error{} = error}, data, state) do
    state = %{state | control_ref: nil, last_result: {:error, error}}

    cond do
      not is_nil(state.intent_ref) ->
        state

      state.run.expected_revision != Map.get(data, :expected_revision) ->
        maybe_start_cancellation(state)

      true ->
        state
    end
  end

  defp handle_task_result(:cleanup_commit, {:ok, committed, prepared}, _data, state) do
    state = %{
      state
      | run: prepared.run,
        budget: prepared.budget,
        control_ref: nil,
        phase: next_phase(prepared.run),
        last_result: {:ok, committed, result(prepared, [])}
    }

    fence_stale_workers(state)
  end

  defp handle_task_result(:cleanup_commit, {:error, %Error{} = error}, _data, state) do
    %{state | control_ref: nil, phase: :cancelling, last_result: {:error, error}}
  end

  defp start_commit(state, meta, role) do
    opts = Keyword.put(state.execution_opts, :budget, state.budget)
    data = %{expected_revision: state.run.expected_revision}

    start_task(state, role, data, fn ->
      Execution.commit(state.store, state.context, state.run, meta, opts)
    end)
  end

  defp start_effect(state, committed, prepared) do
    opts = Keyword.put(state.execution_opts, :budget, prepared.budget)

    start_task(state, :effect, %{committed: committed, prepared: prepared}, fn ->
      Execution.dispatch(prepared, opts)
    end)
  end

  defp start_task(state, role, data, function) do
    task = Task.Supervisor.async_nolink(state.supervisor, function)
    entry = %{task: task, role: role, data: data}
    {%{state | tasks: Map.put(state.tasks, task.ref, entry)}, task.ref}
  end

  defp maybe_start_cancellation(%{control_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_start_cancellation(state) do
    if state.run.state in [:queued, :running, :waiting_approval, :waiting_result] do
      meta = %{command: {:cancel, state.cancel_requested.at}}
      {state, ref} = start_commit(state, meta, :cancel_commit)
      %{state | control_ref: ref, phase: :cancelling}
    else
      state
    end
  end

  defp result(prepared, effects, fenced \\ []) do
    %{
      effects: effects,
      fenced: fenced,
      run: prepared.run,
      budget: prepared.budget,
      operation: prepared.operation
    }
  end

  defp next_phase(run) do
    if Kernel.terminal?(run.state), do: :terminal, else: :idle
  end

  defp cancellation_status(%{cancel_requested: nil}), do: :none
  defp cancellation_status(%{run: %{state: :cancelling}}), do: :cleanup
  defp cancellation_status(_state), do: :accepted

  defp notify_waiters(state) do
    {ready, pending} =
      Enum.split_with(state.state_waiters, fn {_from, run_state} ->
        state.run.state == run_state
      end)

    Enum.each(ready, fn {from, _run_state} -> GenServer.reply(from, status_result(state)) end)
    state = %{state | state_waiters: pending}

    if map_size(state.tasks) == 0 do
      Enum.each(state.waiters, &GenServer.reply(&1, state.last_result))
      %{state | waiters: []}
    else
      state
    end
  end

  defp status_result(state) do
    %{
      phase: state.phase,
      run_state: state.run.state,
      run: state.run,
      cancellation: cancellation_status(state),
      last_result: state.last_result
    }
  end

  defp fence_stale_workers(state) do
    {stale, retained} =
      Enum.split_with(state.tasks, fn {_ref, entry} ->
        entry.role in [:intent_commit, :effect]
      end)

    Enum.each(stale, fn {ref, %{task: task}} ->
      Process.demonitor(ref, [:flush])
      Process.exit(task.pid, :kill)
    end)

    %{state | tasks: Map.new(retained), intent_ref: nil}
  end
end
