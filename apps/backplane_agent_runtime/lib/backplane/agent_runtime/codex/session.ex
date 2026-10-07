defmodule Backplane.AgentRuntime.Codex.Session do
  @moduledoc """
  Host-owned resource lifetime across distinct, bounded Conversation runs.

  Bindings are process-local capabilities. A successful durable run finish must
  acknowledge detachment before another run can bind. Failure, cancellation,
  owner death and uncertain settlement close admission and reconcile resources.
  Restored journal records cannot attach or recreate a binding.
  """
  use GenServer
  require Logger

  alias Backplane.AgentRuntime.{Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, ResourceRegistry}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def bind(session, authority, opts \\ [])

  def bind(session, authority, opts) when is_map(authority) and is_list(opts),
    do: GenServer.call(session, {:bind, authority, opts})

  def bind(_session, _authority, _opts),
    do: {:error, Error.new(:validation, "session binding requires authority and options")}

  def attach(binding, catalog),
    do: GenServer.call(binding.session, {:attach, binding, self(), catalog})

  def validate(binding, operation),
    do: GenServer.call(binding.session, {:validate, binding, operation})

  def prepare_detach(binding),
    do: GenServer.call(binding.session, {:prepare_detach, binding, self()})

  def detach(binding), do: GenServer.call(binding.session, {:detach, binding, self()})

  def close(session_or_binding, opts \\ [])

  def close(%{session: session} = binding, opts),
    do: GenServer.call(session, {:close, binding, opts}, :infinity)

  def close(session, opts) when is_pid(session),
    do: GenServer.call(session, {:close, nil, opts}, :infinity)

  def status(session), do: GenServer.call(session, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.get(opts, :owner_pid)
    timeout = Keyword.get(opts, :cleanup_timeout, 5_000)
    max_turns = Keyword.get(opts, :max_turns, 1_024)

    if is_pid(owner) and Process.alive?(owner) and is_integer(timeout) and timeout in 1..60_000 and
         is_integer(max_turns) and max_turns in 1..100_000 do
      {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: timeout)
      {:ok, supervisor} = Task.Supervisor.start_link()
      owner_id = "session_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      {:ok,
       %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         owner_id: owner_id,
         incarnation: System.unique_integer([:positive, :monotonic]),
         registry: registry,
         supervisor: supervisor,
         cleanup_timeout: timeout,
         phase: :idle,
         active: nil,
         runtimes: [],
         used_runs: MapSet.new(),
         max_turns: max_turns,
         cleanup: :not_requested,
         cleanup_task: nil,
         close_waiters: []
       }}
    else
      {:stop,
       Error.new(:validation, "session requires a live host owner and bounded cleanup timeout")}
    end
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:owner_id, :incarnation, :phase, :cleanup]), state}

  def handle_call({:bind, authority, opts}, _from, %{phase: :idle} = state) do
    run = Map.get(authority, :run_id)
    incarnation = Keyword.get(opts, :incarnation, 1)

    cond do
      not is_binary(run) or run == "" or not is_integer(incarnation) or incarnation <= 0 ->
        {:reply,
         {:error, Error.new(:validation, "session binding requires a fresh run identity")}, state}

      MapSet.member?(state.used_runs, run) ->
        {:reply, {:error, Error.new(:resource_conflict, "session run identity was already used")},
         state}

      MapSet.size(state.used_runs) >= state.max_turns ->
        {:reply, {:error, Error.new(:overloaded, "session turn capacity reached")}, state}

      true ->
        binding = %{
          session: self(),
          token: make_ref(),
          run_id: run,
          run_incarnation: incarnation,
          owner_id: state.owner_id,
          incarnation: state.incarnation,
          owner_pid: self(),
          resource_registry: state.registry
        }

        active = %{binding: binding, pid: nil, monitor: nil, authority: authority}

        {:reply, {:ok, binding},
         %{state | phase: :reserved, active: active, used_runs: MapSet.put(state.used_runs, run)}}
    end
  end

  def handle_call({:bind, _authority, _opts}, _from, state),
    do:
      {:reply, {:error, Error.new(:resource_conflict, "session is not available for a new run")},
       state}

  def handle_call({:attach, binding, pid, catalog}, _from, state) do
    with :ok <- exact_binding(state, binding),
         true <- state.phase == :reserved or refusal("session binding is already attached"),
         true <-
           catalog.authority.run_id == binding.run_id or refusal("session run authority differs") do
      runtimes = Enum.uniq(state.runtimes ++ collaboration_runtimes(catalog.registry))

      case rebind_runtimes(runtimes, binding, catalog.authority) do
        :ok ->
          active = %{
            state.active
            | pid: pid,
              monitor: Process.monitor(pid),
              authority: catalog.authority
          }

          {:reply, :ok, %{state | phase: :active, active: active, runtimes: runtimes}}

        {:error, error, rebound} ->
          state = %{state | runtimes: Enum.uniq(state.runtimes ++ rebound)}
          {:reply, {:error, error}, begin_close(state, [], true)}
      end
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:validate, binding, operation}, _from, state) do
    result =
      with :ok <- exact_binding(state, binding),
           true <- state.phase == :active or refusal("session run is detached or closing"),
           true <-
             (operation.run_id == binding.run_id and
                operation.incarnation == binding.run_incarnation) or
               refusal("stale session run invocation"),
           true <-
             (is_pid(state.active.pid) and Process.alive?(state.active.pid)) or
               refusal("session run owner is unavailable") do
        {:ok, Map.take(binding, [:owner_id, :incarnation, :owner_pid, :resource_registry])}
      end

    {:reply, result, state}
  end

  def handle_call({:prepare_detach, binding, caller}, _from, state) do
    with :ok <- exact_binding(state, binding),
         true <-
           (state.phase == :active and caller == state.active.pid) or
             refusal("only the active run can prepare detachment"),
         :ok <- ResourceRegistry.owner_transfer_ready(state.registry, state.owner_id),
         :ok <- transfer_ready(state.runtimes) do
      {:reply, :ok, %{state | phase: :detaching}}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:detach, binding, caller}, _from, state) do
    with :ok <- exact_binding(state, binding),
         true <-
           (state.phase == :detaching and caller == state.active.pid) or
             refusal("session detachment was not prepared"),
         :ok <- detach_runtimes(state.runtimes, binding) do
      Process.demonitor(state.active.monitor, [:flush])

      {:reply, {:ok, %{status: :retained, owner_id: state.owner_id}},
       %{state | phase: :idle, active: nil}}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close, binding, opts}, from, state) do
    authorized = is_nil(binding) or exact_binding(state, binding) == :ok

    cond do
      not authorized ->
        {:reply, refusal("stale session close binding"), state}

      state.phase == :closed ->
        {:reply, close_result(state.cleanup), state}

      state.phase == :closing ->
        if Keyword.get(opts, :run_fenced, false) and state.active != nil and
             elem(from, 0) == state.active.pid,
           do: send(state.cleanup_task.pid, :run_fenced)

        {:noreply, %{state | close_waiters: [from | state.close_waiters]}}

      true ->
        fenced =
          Keyword.get(opts, :run_fenced, false) and
            state.active != nil and elem(from, 0) == state.active.pid

        {:noreply, begin_close(state, [from], fenced)}
    end
  end

  @impl true
  def handle_info({ref, result}, %{cleanup_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.close_waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | phase: :closed, cleanup: result, cleanup_task: nil, close_waiters: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      state.cleanup_task != nil and ref == state.cleanup_task.ref ->
        result =
          {:error, Error.new(:unknown_outcome, "session cleanup worker stopped", cause: reason)}

        Enum.each(state.close_waiters, &GenServer.reply(&1, result))

        {:noreply,
         %{state | phase: :closed, cleanup: result, cleanup_task: nil, close_waiters: []}}

      ref == state.owner_monitor and state.phase not in [:closed, :closing] ->
        {:noreply, begin_close(state, [], false)}

      state.active != nil and ref == state.active.monitor and
          state.phase not in [:closed, :closing] ->
        {:noreply, begin_close(state, [], true)}

      state.active != nil and ref == state.active.monitor and state.phase == :closing ->
        send(state.cleanup_task.pid, :run_fenced)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    if pid in [state.owner, state.registry, state.supervisor] and
         state.phase not in [:closed, :closing],
       do: {:noreply, begin_close(state, [], false)},
       else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.phase != :closed do
      fence = fence_registry(state)
      deadline = System.monotonic_time(:millisecond) + state.cleanup_timeout

      cancel = fn ->
        if state.active != nil and is_pid(state.active.pid) and Process.alive?(state.active.pid),
          do: Backplane.AgentRuntime.Conversation.cancel(state.active.pid),
          else: :ok
      end

      results = cleanup_all(state, deadline, [cancel])

      unless fence == :ok and Enum.all?(results, &cleanup_confirmed?/1) do
        Logger.error("session shutdown cleanup is unconfirmed", owner_id: state.owner_id)
      end
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp begin_close(state, waiters, fenced) do
    # Admission is fenced before waiting for the run. Cleanup retains its share
    # of the same deadline even when the run cannot acknowledge cancellation.
    admission_fence = fence_registry(state)

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        deadline = System.monotonic_time(:millisecond) + state.cleanup_timeout

        needs_fence =
          state.active != nil and is_pid(state.active.pid) and
            Process.alive?(state.active.pid) and not fenced

        fence =
          if needs_fence do
            receive do
              :run_fenced -> :ok
            after
              max(1, div(state.cleanup_timeout, 2)) ->
                {:error, Error.new(:unknown_outcome, "session run fencing timed out")}
            end
          else
            :ok
          end

        results = cleanup_all(state, deadline)

        if admission_fence == :ok and fence == :ok and Enum.all?(results, &cleanup_confirmed?/1),
          do: {:ok, %{status: :confirmed, owner_id: state.owner_id}},
          else:
            {:error,
             Error.new(:unknown_outcome, "session cleanup is unconfirmed",
               details: %{admission_fence: admission_fence, fencing: fence, results: results}
             )}
      end)

    if state.active != nil and is_pid(state.active.pid) and not fenced,
      do: send(state.active.pid, {:codex_session_close, state.active.binding.token})

    %{state | phase: :closing, cleanup_task: task, close_waiters: waiters}
  end

  defp fence_registry(state) do
    ResourceRegistry.fence_owner(state.registry, state.owner_id)
  catch
    :exit, reason ->
      {:error,
       Error.new(:unknown_outcome, "session registry fence is unavailable", cause: reason)}
  end

  defp cleanup_all(state, deadline, extra \\ []) do
    callbacks =
      extra ++
        [fn -> ResourceRegistry.close_owner(state.registry, state.owner_id) end] ++
        Enum.map(state.runtimes, fn runtime ->
          fn -> MultiAgent.close_session(runtime, state.owner_id, state.incarnation) end
        end)

    tasks = Enum.map(callbacks, &Task.Supervisor.async_nolink(state.supervisor, &1))

    tasks
    |> Task.yield_many(max(0, deadline - System.monotonic_time(:millisecond)))
    |> Enum.map(fn
      {_task, {:ok, result}} ->
        result

      {_task, {:exit, reason}} ->
        {:error, reason}

      {task, nil} ->
        Task.shutdown(task, :brutal_kill)
        {:error, :cleanup_deadline_exceeded}
    end)
  end

  defp cleanup_confirmed?({:ok, entries}) when is_list(entries),
    do: Enum.all?(entries, &match?({:ok, _}, &1))

  defp cleanup_confirmed?(:ok), do: true
  defp cleanup_confirmed?(_), do: false

  defp close_result(:not_requested),
    do: {:error, Error.new(:unknown_outcome, "session cleanup is unavailable")}

  defp close_result(result), do: result

  defp exact_binding(%{active: %{binding: actual}}, binding) when actual == binding, do: :ok
  defp exact_binding(_, _), do: refusal("stale or foreign session binding")
  defp refusal(message), do: {:error, Error.new(:forbidden, message)}

  defp collaboration_runtimes(%ToolRegistry{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.flat_map(fn descriptor ->
      case descriptor[:backend_context] do
        %{family: :collaboration, runtime: runtime} when is_pid(runtime) -> [runtime]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp rebind_runtimes(runtimes, binding, authority) do
    Enum.reduce_while(runtimes, {:ok, []}, fn runtime, {:ok, rebound} ->
      result =
        try do
          MultiAgent.rebind_parent(runtime, binding, authority)
        catch
          :exit, reason ->
            {:error,
             Error.new(:unknown_outcome, "collaboration binding acknowledgement is unavailable",
               cause: reason
             )}
        end

      case result do
        :ok -> {:cont, {:ok, [runtime | rebound]}}
        {:error, error} -> {:halt, {:error, error, [runtime | rebound]}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp detach_runtimes(runtimes, binding),
    do: each_runtime(runtimes, &MultiAgent.detach_parent(&1, binding))

  defp transfer_ready(runtimes), do: each_runtime(runtimes, &MultiAgent.transfer_ready/1)

  defp each_runtime(runtimes, callback) do
    Enum.reduce_while(runtimes, :ok, fn runtime, :ok ->
      case callback.(runtime) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end
end
