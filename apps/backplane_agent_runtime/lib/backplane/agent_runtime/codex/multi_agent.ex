defmodule Backplane.AgentRuntime.Codex.MultiAgent do
  @moduledoc """
  Supervised Codex V1/V2 collaboration runtime.

  The process owns only collaboration state and waiters. Child work is executed by
  real `Conversation` processes under a `DynamicSupervisor`.
  """

  use GenServer

  alias Backplane.AgentRuntime.{Conversation, Error, Goal, ToolEffects}

  alias Backplane.AgentRuntime.Execution

  @default_wait_timeout_ms 30_000
  @maximum_wait_timeout_ms 3_600_000
  @settlement_wait_ms 5_000
  @v1_namespace "multi_agent_v1"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def rebind_parent(runtime, binding, authority),
    do: GenServer.call(runtime, {:rebind_parent, binding, authority})

  def detach_parent(runtime, binding), do: GenServer.call(runtime, {:detach_parent, binding})
  def transfer_ready(runtime), do: GenServer.call(runtime, :transfer_ready)
  def close_session(runtime), do: GenServer.call(runtime, :close_session, :infinity)

  def close_session(runtime, owner_id, incarnation),
    do: GenServer.call(runtime, {:close_session, {owner_id, incarnation}}, :infinity)

  def snapshot(runtime), do: GenServer.call(runtime, :snapshot)
  def subscribe(runtime, observer \\ self()), do: GenServer.call(runtime, {:subscribe, observer})

  def unsubscribe(runtime, observer \\ self()),
    do: GenServer.call(runtime, {:unsubscribe, observer})

  @spec contracts(:v1 | :v2, pid(), keyword()) :: [map()]
  def contracts(profile, runtime, opts \\ []) when profile in [:v1, :v2] and is_pid(runtime) do
    runtime_wait = GenServer.call(runtime, :wait_options)

    wait = %{
      default: Keyword.get(opts, :default_wait_timeout_ms, runtime_wait.default_wait_timeout_ms),
      min: Keyword.get(opts, :min_wait_timeout_ms, runtime_wait.min_wait_timeout_ms),
      max: Keyword.get(opts, :max_wait_timeout_ms, runtime_wait.max_wait_timeout_ms)
    }

    case profile do
      :v1 -> v1_contracts(runtime, wait)
      :v2 -> v2_contracts(runtime, wait)
    end
  end

  @spec call(map()) :: ToolEffects.result()
  def call(%{backend_context: %{runtime: runtime, profile: profile}} = operation)
      when is_pid(runtime) and profile in [:v1, :v2] do
    GenServer.call(runtime, {:tool, profile, operation}, :infinity)
  catch
    :exit, reason ->
      {:error,
       Error.new(:execution_failure, "collaboration runtime is unavailable", cause: reason)}
  end

  def call(_operation),
    do: {:error, Error.new(:unsupported_capability, "collaboration runtime is unavailable")}

  @impl true
  def init(opts) do
    with {:ok, parent_run_id} <- required_binary(opts, :parent_run_id),
         {:ok, parent_name} <- required_binary(opts, :parent_name),
         {:ok, authority} <- required_map(opts, :parent_authority),
         {:ok, child_options} <- required_callback(opts, :child_options, 3),
         {:ok, admission_receipt} <- optional_callback(opts, :admission_receipt, 1),
         {:ok, v2_child_limit} <- child_limit(opts),
         {:ok, supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
      {:ok,
       %{
         parent_run_id: parent_run_id,
         root_id: parent_run_id,
         parent_name: normalize_root(parent_name),
         parent_authority: authority,
         root_goal_context: %{},
         session_authority: nil,
         parent_binding: nil,
         parent_pid: nil,
         parent_incarnation: 1,
         parent_monitor: nil,
         parent_recovery: false,
         mailboxes: %{},
         input_activity: %{},
         deliveries: %{},
         session_owner: nil,
         session_closed: false,
         child_options: child_options,
         admission_receipt: admission_receipt,
         admissions: %{},
         child_supervisor: supervisor,
         subscriber: Keyword.get(opts, :subscriber),
         manager_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
         revision: 0,
         observers:
           case Keyword.get(opts, :subscriber) do
             pid when is_pid(pid) -> %{pid => Process.monitor(pid)}
             _ -> %{}
           end,
         min_wait_timeout_ms: Keyword.get(opts, :min_wait_timeout_ms, 10_000),
         max_wait_timeout_ms: Keyword.get(opts, :max_wait_timeout_ms, @maximum_wait_timeout_ms),
         default_wait_timeout_ms:
           Keyword.get(opts, :default_wait_timeout_ms, @default_wait_timeout_ms),
         max_agents: Keyword.get(opts, :max_agents, 16),
         v2_child_limit: v2_child_limit,
         sequence: 0,
         agents: %{},
         run_index: %{},
         monitors: %{},
         updates: MapSet.new(),
         waiters: %{}
       }}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, public_snapshot(state)}, state}

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    state =
      if Map.has_key?(state.observers, pid),
        do: state,
        else: %{state | observers: Map.put(state.observers, pid, Process.monitor(pid))}

    {:reply, {:ok, public_snapshot(state)}, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) when is_pid(pid) do
    if ref = state.observers[pid], do: Process.demonitor(ref, [:flush])

    {:reply, :ok,
     %{
       state
       | observers: Map.delete(state.observers, pid),
         subscriber: if(state.subscriber == pid, do: nil, else: state.subscriber)
     }}
  end

  def handle_call({:rebind_parent, binding, authority}, _from, state) do
    owner = {binding.owner_id, binding.incarnation}

    cond do
      state.session_closed ->
        {:reply, {:error, Error.new(:forbidden, "collaboration session is closed")}, state}

      state.session_owner != nil and state.session_owner != owner ->
        {:reply, {:error, Error.new(:forbidden, "collaboration belongs to another session")},
         state}

      state.parent_binding != nil and state.parent_binding != binding ->
        {:reply,
         {:error, Error.new(:resource_conflict, "collaboration parent is still attached")}, state}

      true ->
        {:reply, :ok,
         %{
           state
           | parent_run_id: binding.run_id,
             parent_incarnation: Map.get(binding, :run_incarnation, 1),
             parent_pid: state.parent_pid,
             parent_recovery: false,
             input_activity:
               if(state.parent_binding == binding,
                 do: state.input_activity,
                 else: reset_input_activity(state, state.parent_name).input_activity
               ),
             parent_authority: authority,
             session_authority: authority,
             parent_binding: binding,
             session_owner: owner
         }}
    end
  end

  def handle_call({:detach_parent, binding}, _from, state) do
    if state.parent_binding == binding do
      if state.parent_monitor, do: Process.demonitor(state.parent_monitor, [:flush])
      next = reset_input_activity(state, state.parent_name)

      {:reply, :ok,
       %{next | parent_binding: nil, parent_run_id: nil, parent_pid: nil, parent_monitor: nil}}
    else
      {:reply, {:error, Error.new(:forbidden, "stale collaboration parent binding")}, state}
    end
  end

  def handle_call(:transfer_ready, _from, state) do
    ready =
      Enum.all?(state.agents, fn {_name, agent} ->
        case transfer_snapshot(agent) do
          {:ok, snapshot} ->
            snapshot.run.state != :unknown_outcome and
              not match?({:uncertain, _}, snapshot.resource_cleanup)

          {:error, _} ->
            false
        end
      end)

    result =
      if ready,
        do: :ok,
        else:
          {:error, Error.new(:unknown_outcome, "collaboration resources require reconciliation")}

    {:reply, result, state}
  end

  def handle_call(:close_session, _from, state) do
    close_session_state(state)
  end

  def handle_call({:close_session, owner}, _from, state) do
    if state.session_owner == owner,
      do: close_session_state(state),
      else: {:reply, :ok, state}
  end

  def handle_call(:wait_options, _from, state) do
    {:reply,
     Map.take(state, [
       :default_wait_timeout_ms,
       :min_wait_timeout_ms,
       :max_wait_timeout_ms
     ]), state}
  end

  def handle_call({:tool, profile, operation}, from, state) do
    with {:ok, caller} <- authenticate(operation, state),
         {:ok, action} <- action(profile, operation.tool_name) do
      state =
        if caller.name == state.parent_name,
          do: %{
            state
            | parent_authority: caller.authority,
              root_goal_context: Map.take(caller, [:goal, :goal_binding])
          },
          else: state

      case dispatch(action, operation.arguments, from, caller, state) do
        {:reply, {:refused, error}, next} -> rejection_reply(operation, error, next)
        result -> result
      end
    else
      {:error, %Error{} = error} -> rejection_reply(operation, error, state)
    end
  end

  # Only explicit refusal branches may assert non-dispatch. Legacy direct callers
  # without an invocation identity retain their ordinary error result.
  defp rejection_reply(operation, error, state) do
    result =
      case ToolEffects.reject(operation, error) do
        {:rejected, _} = rejection -> rejection
        {:error, _} -> {:error, error}
      end

    {:reply, result, state}
  end

  defp close_session_state(state) do
    state = %{state | session_closed: true, parent_run_id: nil, parent_binding: nil}

    {state, errors} =
      Enum.reduce(Map.keys(state.agents), {state, []}, fn name, {current, errors} ->
        case cancel_owned_tree(current, name, :close) do
          {:ok, next} -> {next, errors}
          {:error, error, next} -> {next, [error | errors]}
        end
      end)

    result =
      if errors == [],
        do: :ok,
        else:
          {:error,
           Error.new(:unknown_outcome, "collaboration session cleanup is unconfirmed",
             details: %{errors: errors}
           )}

    {:reply, result, state}
  end

  @impl true
  def handle_info({:codex_bind_input, pid, identity}, state) do
    result =
      cond do
        state.session_closed ->
          {:error, Error.new(:forbidden, "collaboration session is closed")}

        identity.run_id != state.parent_run_id or identity.incarnation != state.parent_incarnation or
            identity.session_binding != state.parent_binding ->
          {:error, Error.new(:forbidden, "stale collaboration input binding")}

        state.parent_pid != nil and state.parent_pid != pid ->
          {:error, Error.new(:forbidden, "collaboration input already has an owner")}

        true ->
          :ok
      end

    case result do
      :ok ->
        entries = Map.get(state.mailboxes, state.parent_name, [])
        send(pid, {:codex_input_bound, self(), identity, {:ok, entries}})
        ref = state.parent_monitor || Process.monitor(pid)

        {:noreply,
         %{
           state
           | parent_pid: pid,
             parent_monitor: ref,
             mailboxes: Map.delete(state.mailboxes, state.parent_name)
         }}

      error ->
        send(pid, {:codex_input_bound, self(), identity, error})
        {:noreply, state}
    end
  end

  def handle_info({:codex_input_activity, pid, identity, activity}, state) do
    case input_owner(state, pid, identity) do
      nil ->
        {:noreply, state}

      name
      when name == state.parent_name and is_tuple(activity) and elem(activity, 0) == :settled ->
        if state.parent_monitor, do: Process.demonitor(state.parent_monitor, [:flush])
        {:settled, mailbox} = activity
        entries = Map.get(state.mailboxes, name, []) ++ mailbox

        next = %{
          state
          | parent_pid: nil,
            parent_monitor: nil,
            parent_recovery: false,
            mailboxes: Map.put(state.mailboxes, name, Enum.uniq_by(entries, & &1.id))
        }

        {:noreply, next |> reset_input_activity(name) |> wake_waiters()}

      _name when is_tuple(activity) ->
        {:noreply, state}

      name ->
        {:noreply, state |> change_input_activity(name, activity) |> wake_waiters()}
    end
  end

  def handle_info({:mail_delivery, token, result}, state),
    do: {:noreply, complete_delivery(state, token, result)}

  def handle_info({:mail_delivery_timeout, token}, state) do
    if delivery = state.deliveries[token], do: Process.exit(delivery.worker, :kill)

    {:noreply,
     complete_delivery(
       state,
       token,
       {:error, Error.new(:unknown_outcome, "mailbox acceptance was not acknowledged")}
     )}
  end

  def handle_info({:agent_runtime, run_id, event}, state) when is_map(event) do
    state = update_from_event(state, run_id, event)
    {:noreply, wake_waiters(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    observer = Enum.find(state.observers, fn {_pid, monitor} -> monitor == ref end)

    case {observer, Map.pop(state.monitors, ref)} do
      _ when ref == state.parent_monitor ->
        {:noreply, %{state | parent_pid: nil, parent_monitor: nil, parent_recovery: true}}

      {{pid, _}, _} ->
        {:noreply,
         %{
           state
           | observers: Map.delete(state.observers, pid),
             subscriber: if(state.subscriber == pid, do: nil, else: state.subscriber)
         }}

      {nil, {nil, _}} ->
        {:noreply, state}

      {nil, {{name, run_id}, monitors}} ->
        state = %{state | monitors: monitors}

        if get_in(state, [:agents, name, :run_id]) == run_id do
          agent = state.agents[name]

          next_agent =
            if is_map(agent.snapshot) and
                 not match?({:uncertain, _}, agent.closure) do
              %{agent | pid: nil, monitor: nil}
            else
              %{
                agent
                | pid: nil,
                  monitor: nil,
                  status:
                    if(agent.status in [:interrupted, :shutdown],
                      do: agent.status,
                      else: {:errored, inspect(reason)}
                    ),
                  execution_reserved: true,
                  snapshot: nil,
                  snapshot_identity: nil,
                  closure:
                    {:uncertain, Error.new(:unknown_outcome, "agent exited before settlement")}
              }
            end

          state = put_in(state, [:agents, name], next_agent)
          state = %{state | updates: MapSet.put(state.updates, name)}
          state = publish(state, :process_exited, name)
          {:noreply, wake_waiters(state)}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:wait_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, profile: :v1}, waiters} ->
        GenServer.reply(from, {:ok, %{status: %{}, timed_out: true}})
        {:noreply, %{state | waiters: waiters}}

      {%{from: from, profile: :v2}, waiters} ->
        GenServer.reply(
          from,
          {:ok, %{message: "Wait timed out.", timed_out: true}}
        )

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.deliveries, fn {_token, entry} ->
      Process.cancel_timer(entry.timer)
      Process.exit(entry.worker, :kill)
    end)

    Enum.each(state.waiters, fn {_token, waiter} ->
      if waiter.timer, do: Process.cancel_timer(waiter.timer)
    end)

    if Process.alive?(state.child_supervisor),
      do: Supervisor.stop(state.child_supervisor, :shutdown)

    :ok
  end

  defp dispatch({:spawn, profile}, arguments, _from, caller, state) do
    with {:ok, request} <- spawn_request(arguments, profile),
         {:ok, name} <- child_name(caller, request.task_name),
         :ok <- unique_name(state, name) do
      case prepare_activation(state, profile) do
        {:ok, state} -> spawn_child(arguments, caller, state, profile)
        {:refused, error, state} -> {:reply, {:refused, error}, state}
        {:error, error, state} -> {:reply, {:error, error}, state}
      end
    else
      {:error, error} -> {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(:list, arguments, _from, _caller, state) do
    prefix = arguments["path_prefix"]

    agents =
      state.agents
      |> Map.values()
      |> Enum.reject(&(&1.status == :shutdown))
      |> Enum.filter(&(is_nil(prefix) or String.starts_with?(&1.name, prefix)))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&%{agent_name: &1.name, agent_status: public_status(&1)})

    {:reply, {:ok, %{agents: agents}}, state}
  end

  defp dispatch(:wait_v2, arguments, from, caller, state) do
    case caller_activity(state, caller.name) do
      nil -> wait(:v2, [], arguments, from, caller, state)
      activity -> {:reply, {:ok, v2_wait_result(activity)}, state}
    end
  end

  defp dispatch(:wait_v1, arguments, from, caller, state) do
    targets = arguments["targets"] || []

    with true <-
           (is_list(targets) and targets != []) or validation("targets must be a non-empty list"),
         {:ok, names} <- resolve_targets(state, targets) do
      case ready_names(state, names) do
        [] -> wait(:v1, names, arguments, from, caller, state)
        ready -> {:reply, {:ok, v1_wait_result(state, ready)}, consume_updates(state, ready)}
      end
    else
      {:error, %Error{} = error, next} ->
        {:reply, {:error, error}, next}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp dispatch(:message, arguments, from, caller, state) do
    with message when is_binary(message) and message != "" <- arguments["message"],
         {:ok, name, destination} <- mailbox_destination(state, arguments["target"]) do
      queue_message(
        state,
        name,
        destination,
        message,
        communication(caller, :message, unique_id("mail")),
        from,
        nil
      )
    else
      {:error, error} ->
        {:reply, {:refused, error}, state}

      _ ->
        {:error, error} = validation("message is required")
        {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(action, arguments, _from, _caller, state)
       when action == :followup_v2 do
    target = arguments["target"]
    message = arguments["message"]

    with true <-
           (is_binary(message) and String.trim(message) != "") or
             validation("message is required"),
         {:ok, name, agent} <- resolve_target(state, target) do
      case deliver(state, name, agent, action, message) do
        {:ok, state} ->
          state = %{state | updates: MapSet.put(state.updates, name)}
          {:reply, {:ok, %{accepted: true}}, wake_waiters(state)}

        {:refused, error, next} ->
          {:reply, {:refused, error}, next}

        {:error, error, next} ->
          {:reply, {:error, error}, next}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{} = error} -> {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(:send_input, arguments, _from, _caller, state) do
    message = arguments["message"] || input_items_text(arguments["items"])
    action = if arguments["interrupt"] == true, do: :interrupt_message, else: :followup

    with true <-
           (is_binary(message) and String.trim(message) != "") or
             validation("message or items is required"),
         {:ok, name, agent} <- resolve_target(state, arguments["target"]) do
      case deliver(state, name, agent, action, message) do
        {:ok, state} ->
          {:reply, {:ok, %{submission_id: unique_id("submission")}}, state}

        {:refused, error, next} ->
          {:reply, {:refused, error}, next}

        {:error, error, next} ->
          {:reply, {:error, error}, next}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{} = error} -> {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(:interrupt, arguments, _from, caller, state) do
    target = arguments["target"]

    with :ok <- reject_interrupt_target(state, caller, target),
         {:ok, name, agent} <- resolve_target(state, target),
         :ok <- reject_interrupt_target(state, caller, name) do
      previous = public_status(agent)

      case interrupt_target(state, name, agent) do
        {:ok, next} ->
          {:reply, {:ok, %{previous_status: previous, status: public_status(next.agents[name])}},
           wake_waiters(next)}

        {:error, error, next} ->
          {:reply, {:error, error}, wake_waiters(next)}
      end
    else
      {:error, error} -> {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(:close, arguments, _from, _caller, state) do
    case resolve_target(state, arguments["target"]) do
      {:ok, name, agent} ->
        previous = public_status(agent)

        case cancel_owned_tree(state, name, :close) do
          {:ok, state} ->
            next_status = :shutdown

            {:reply, {:ok, %{previous_status: previous, status: next_status}},
             wake_waiters(state)}

          {:error, %Error{} = error, state} ->
            {:reply, {:error, error}, wake_waiters(state)}
        end

      {:error, %Error{} = error} ->
        {:reply, {:refused, error}, state}
    end
  end

  defp dispatch(:resume, arguments, _from, _caller, state) do
    with {:ok, name, agent} <- resolve_target(state, arguments["id"]),
         true <- agent.status == :shutdown or validation("agent is not closed") do
      case replace_agent(state, name, agent, nil) do
        {:ok, next} -> {:reply, {:ok, %{status: :running}}, next}
        {:error, error, next} -> {:reply, {:error, error}, next}
        {:error, error} -> {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{} = error} -> {:reply, {:refused, error}, state}
    end
  end

  defp spawn_child(arguments, caller, state, profile) do
    with {:ok, request} <- spawn_request(arguments, profile),
         {:ok, name} <- child_name(caller, request.task_name),
         :ok <- unique_name(state, name) do
      parent_id =
        if caller.name == state.parent_name,
          do: state.root_id,
          else: state.agents[caller.name].id

      {state, attempt} =
        reserve_admission(state, %{
          name: name,
          profile: profile,
          parent_id: parent_id,
          parent_name: caller.name,
          incarnation: 1,
          activation: :created
        })

      parent = Map.put(caller_metadata(caller), :child, admission_child(attempt))

      case prepare_child(state, request, attempt, parent) do
        {:ok, opts, host_metadata} ->
          opts = Keyword.put(opts, :subscriber, self())

          agent = %{
            name: name,
            id: attempt.agent_id,
            attempt_id: attempt.attempt_id,
            run_id: attempt.run_id,
            incarnation: 1,
            host_metadata: host_metadata,
            pid: nil,
            monitor: nil,
            status: :created,
            final: nil,
            result_delivery: nil,
            opts: opts,
            request: request,
            message: request.message,
            profile: profile,
            parent: caller.name,
            parent_id: parent_id,
            authority: Keyword.get(opts, :authority, %{}),
            snapshot: nil,
            snapshot_identity: nil,
            closure: :open,
            execution_reserved: true
          }

          state =
            %{
              state
              | agents: Map.put(state.agents, name, agent),
                run_index: Map.put(state.run_index, attempt.run_id, name)
            }
            |> publish(:created, name)

          result =
            if profile == :v1,
              do: %{agent_id: attempt.run_id, nickname: nil},
              else: %{task_name: name, nickname: nil}

          case activate_child(state, name, opts, request.message) do
            {:ok, next} -> {:reply, {:ok, result}, next}
            {:error, error, next} -> {:reply, {:error, error}, next}
          end

        {:error, error} ->
          {error, next} = reject_admission(state, attempt, :rejected, error)
          {:reply, {:error, error}, next}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  defp wait(profile, names, arguments, from, caller, state) do
    with {:ok, timeout} <- wait_timeout(arguments["timeout_ms"], state),
         :ok <- reject_wait_cycle(profile, caller.name, names, state) do
      token = make_ref()
      timer = Process.send_after(self(), {:wait_timeout, token}, timeout)
      waiter = %{from: from, profile: profile, names: names, timer: timer, caller: caller.name}
      {:noreply, put_in(state, [:waiters, token], waiter)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  defp wake_waiters(state) do
    {state, consumed} =
      Enum.reduce(Map.to_list(state.waiters), {state, MapSet.new()}, fn {token, waiter},
                                                                        {acc, consumed} ->
        names = if waiter.profile == :v1, do: ready_names(state, waiter.names), else: []
        activity = if waiter.profile == :v2, do: caller_activity(state, waiter.caller), else: nil

        if names == [] and activity == nil do
          {acc, consumed}
        else
          Process.cancel_timer(waiter.timer)

          result =
            if waiter.profile == :v1,
              do: v1_wait_result(state, names),
              else: v2_wait_result(activity)

          GenServer.reply(waiter.from, {:ok, result})

          {%{acc | waiters: Map.delete(acc.waiters, token)},
           Enum.reduce(names, consumed, &MapSet.put(&2, &1))}
        end
      end)

    consume_updates(state, MapSet.to_list(consumed))
  end

  defp update_from_event(state, run_id, %{type: type} = event)
       when type in [:run_completed, :run_failed, :run_cancelled] do
    case Map.fetch(state.run_index, run_id) do
      :error ->
        state

      {:ok, name} ->
        agent = Map.fetch!(state.agents, name)

        if agent.run_id != run_id or agent.status != :running or
             event[:incarnation] != agent.incarnation do
          state
        else
          status =
            case {type, agent.status} do
              {:run_completed, _status} -> :completed
              {:run_cancelled, _status} -> :interrupted
              {_type, _status} -> {:errored, event_error(event)}
            end

          final = terminal_message(agent.pid, event)

          state =
            state
            |> put_in([:agents, name, :status], status)
            |> put_in([:agents, name, :final], final)
            |> Map.update!(:updates, &MapSet.put(&1, name))

          next = settle_v2_agent(state, name)

          if match?({:uncertain, _}, next.agents[name].closure),
            do: next,
            else: next |> publish(:settled, name) |> deliver_terminal_result(name)
        end
    end
  end

  defp update_from_event(state, _run_id, _event), do: state

  defp terminal_message(pid, event) do
    case Conversation.status(pid) do
      %{messages: messages} ->
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: :assistant, content: content} -> content
          %{role: "assistant", content: content} -> content
          _ -> nil
        end) || inspect(Map.get(event, :outcome))

      _ ->
        inspect(Map.get(event, :outcome))
    end
  catch
    :exit, _ -> inspect(Map.get(event, :outcome))
  end

  defp deliver(state, name, agent, :interrupt_message, message) do
    with :ok <- cancel_agent(agent),
         {:ok, state} <- replace_agent(state, name, agent, message) do
      {:ok, state}
    else
      # Cancellation already ran, so replacement refusal cannot prove non-dispatch.
      {:refused, error, next} -> {:error, error, next}
      error -> error
    end
  end

  defp deliver(_state, _name, %{closure: {:uncertain, _}}, _action, _message),
    do: {:error, Error.new(:unknown_outcome, "agent cleanup is not settled")}

  defp deliver(state, _name, %{status: :running, pid: pid}, :followup, message),
    do: normalize_delivery(state, Conversation.follow_up(pid, message))

  defp deliver(state, _name, %{status: :running, pid: pid}, :followup_v2, message),
    do: normalize_delivery(state, Conversation.follow_up(pid, message))

  defp deliver(state, name, %{status: status} = agent, :followup, message)
       when status in [:completed, :interrupted],
       do: replace_agent(state, name, agent, message)

  defp deliver(state, name, %{status: {:errored, _}, profile: :v2} = agent, :followup, message),
    do: replace_agent(state, name, agent, message)

  defp deliver(state, name, %{status: status} = agent, :followup_v2, message)
       when status in [:completed, :interrupted],
       do: replace_agent(state, name, agent, message, :v2)

  defp deliver(state, name, %{status: {:errored, _}} = agent, :followup_v2, message),
    do: replace_agent(state, name, agent, message, :v2)

  defp deliver(_state, _name, _agent, _action, _message),
    do: {:error, Error.new(:resource_conflict, "agent is not accepting input")}

  defp normalize_delivery(state, {:ok, _}), do: {:ok, state}
  defp normalize_delivery(_state, {:error, %Error{} = error}), do: {:error, error}

  defp replace_agent(state, name, agent, message, admission_profile \\ :v1) do
    with {:ok, snapshot} <- settled_snapshot(agent),
         :ok <- safe_replacement(snapshot) do
      case prepare_activation(state, admission_profile, name) do
        {:ok, next} -> start_replacement(next, name, next.agents[name], message, snapshot)
        {:refused, error, next} -> {:refused, error, next}
        {:error, error, next} -> {:error, error, next}
      end
    end
  end

  defp start_replacement(state, name, agent, message, snapshot) do
    incarnation = agent.incarnation + 1

    {state, attempt} =
      reserve_admission(state, %{
        name: name,
        profile: agent.profile,
        agent_id: agent.id,
        parent_id: agent.parent_id,
        parent_name: agent.parent,
        incarnation: incarnation,
        activation: if(message == nil, do: :resumed, else: :followup)
      })

    parent = Map.put(parent_metadata(state, agent), :child, admission_child(attempt))

    case prepare_child(state, agent.request, attempt, parent, snapshot.run, agent.authority) do
      {:ok, opts, host_metadata} ->
        opts =
          opts
          |> Keyword.put(:messages, snapshot.messages)
          |> Keyword.put(:subscriber, self())
          |> Keyword.put(
            :mailbox,
            Map.get(snapshot.conversation, :mailbox, []) ++ Map.get(state.mailboxes, name, [])
          )

        case retire_replaced_child(state, agent) do
          :ok ->
            replacement = %{
              agent
              | run_id: attempt.run_id,
                attempt_id: attempt.attempt_id,
                incarnation: incarnation,
                host_metadata: host_metadata,
                pid: nil,
                monitor: nil,
                opts: opts,
                authority: Keyword.get(opts, :authority, %{}),
                status: :created,
                final: nil,
                result_delivery: nil,
                snapshot: nil,
                snapshot_identity: nil,
                closure: :open,
                execution_reserved: true
            }

            state =
              %{
                state
                | agents: Map.put(state.agents, name, replacement),
                  run_index: Map.put(state.run_index, attempt.run_id, name),
                  monitors: Map.delete(state.monitors, agent.monitor),
                  updates: MapSet.delete(state.updates, name)
              }
              |> reset_input_activity(name, Keyword.get(opts, :mailbox, []))

            case activate_child(state, name, opts, message) do
              {:ok, next} -> {:ok, %{next | mailboxes: Map.delete(next.mailboxes, name)}}
              error -> error
            end

          {:error, error} ->
            {error, next} = reject_admission(state, attempt, :failed, error)
            {:error, error, reserve_uncertain(next, name, error)}
        end

      {:error, error} ->
        {error, next} = reject_admission(state, attempt, :rejected, error)
        {:error, error, next}
    end
  end

  defp retire_replaced_child(_state, %{pid: nil}), do: :ok

  defp retire_replaced_child(state, agent) do
    with :ok <- safe_terminate_child(state.child_supervisor, agent.pid),
         do: safe_demonitor(agent.monitor)
  end

  defp activate_child(state, name, opts, message) do
    opts = Keyword.put(opts, :collaboration_input, %{runtime: self(), name: name})
    attempt = state.admissions[state.agents[name].attempt_id]

    case admission_operation(fn -> start_child(state.child_supervisor, opts) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        agent = %{state.agents[name] | pid: pid, monitor: ref}

        next =
          state
          |> put_in([:agents, name], agent)
          |> Map.update!(:monitors, &Map.put(&1, ref, {name, agent.run_id}))

        case record_admission(next, attempt, :created, nil) do
          {:ok, next} ->
            next = next |> put_in([:agents, name, :status], :running) |> publish(:started, name)

            case admission_operation(fn -> maybe_prompt(pid, message) end) do
              :ok -> {:ok, next}
              {:error, error} -> fail_activation(next, name, attempt, error)
            end

          {:error, error, next} ->
            fail_activation(next, name, attempt, error)
        end

      {:error, error} ->
        agent = %{
          state.agents[name]
          | status: {:errored, :startup_failure},
            execution_reserved: false,
            closure: :confirmed
        }

        next = state |> put_in([:agents, name], agent) |> publish(:settled, name)
        {error, next} = reject_admission(next, attempt, :failed, error)
        {:error, error, next}
    end
  end

  defp fail_activation(state, name, attempt, error) do
    agent = state.agents[name]

    cleanup =
      admission_operation(fn ->
        with :ok <- cancel_agent(agent),
             {:ok, snapshot} <- settled_snapshot(agent),
             :ok <- safe_replacement(snapshot),
             :ok <- safe_terminate_child(state.child_supervisor, agent.pid),
             :ok <- safe_demonitor(agent.monitor),
             do: {:ok, snapshot}
      end)

    next =
      case cleanup do
        {:ok, snapshot} ->
          failed = %{
            agent
            | status: {:errored, :admission_failure},
              pid: nil,
              monitor: nil,
              execution_reserved: false,
              closure: :confirmed,
              snapshot: snapshot,
              snapshot_identity: snapshot_identity(snapshot)
          }

          %{
            state
            | agents: Map.put(state.agents, name, failed),
              monitors: Map.delete(state.monitors, agent.monitor)
          }
          |> publish(:settled, name)

        {:error, cleanup_error} ->
          reserve_uncertain(state, name, cleanup_error)
      end

    {error, next} = reject_admission(next, attempt, :failed, error)
    {:error, error, next}
  end

  defp prepare_child(
         state,
         request,
         attempt,
         parent,
         previous_run \\ nil,
         previous_authority \\ nil
       ) do
    admission_operation(fn ->
      with {:ok, opts} <-
             child_options_reply(state.child_options.(request, attempt.run_id, parent)),
           :ok <- child_options_shape(opts),
           :ok <- child_authority(opts, parent.authority),
           :ok <- previous_child_authority(opts, previous_authority),
           {:ok, opts, metadata} <-
             child_configuration(opts, attempt.run_id, attempt.incarnation),
           {:ok, opts} <- previous_child_limits(opts, previous_run),
           {:ok, opts} <- attribute_child(opts, parent),
           do: {:ok, opts, metadata}
    end)
  end

  defp child_options_reply({:ok, opts}), do: {:ok, opts}
  defp child_options_reply({:error, %Error{}} = error), do: error
  defp child_options_reply(_), do: validation("child options callback returned an invalid result")

  defp child_options_shape(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: :ok,
      else: validation("child options must be a keyword list")
  end

  defp previous_child_authority(_opts, nil), do: :ok
  defp previous_child_authority(opts, authority), do: child_authority(opts, authority)
  defp previous_child_limits(opts, nil), do: {:ok, opts}
  defp previous_child_limits(opts, run), do: carry_limits(opts, run)

  defp admission_operation(operation) do
    case operation.() do
      :ok ->
        :ok

      {:ok, _} = result ->
        result

      {:ok, _, _} = result ->
        result

      {:error, %Error{} = error} ->
        details = if is_map(error.details), do: error.details, else: %{}
        {:error, Error.new(error.class, error.message, details: details)}

      _ ->
        {:error, Error.new(:execution_failure, "child admission operation failed")}
    end
  rescue
    _ -> {:error, Error.new(:execution_failure, "child admission operation raised")}
  catch
    _, _ -> {:error, Error.new(:execution_failure, "child admission operation exited")}
  end

  defp child_configuration(opts, run_id, incarnation) do
    metadata = Keyword.get(opts, :host_metadata, %{})

    cond do
      Keyword.get(opts, :run_id) != run_id or
          Keyword.get(opts, :incarnation, incarnation) != incarnation ->
        {:error, Error.new(:validation, "child identity differs from allocated identity")}

      not is_map(metadata) or not public_metadata?(metadata) ->
        {:error, Error.new(:validation, "host metadata must contain safe JSON values")}

      true ->
        {:ok, opts |> Keyword.delete(:host_metadata) |> Keyword.put(:incarnation, incarnation),
         metadata}
    end
  end

  defp public_metadata?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, nested} ->
        (is_binary(key) or is_atom(key)) and
          to_string(key) not in ~w(pid opts authority grants store provider provider_context) and
          public_metadata?(nested)
      end)
  end

  defp public_metadata?(value) when is_list(value), do: Enum.all?(value, &public_metadata?/1)

  defp public_metadata?(value),
    do: is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value)

  defp attribute_child(opts, %{goal: goal, goal_binding: binding})
       when is_pid(goal) and is_map(binding) do
    attrs = %{
      thread_id: Keyword.get(opts, :thread_id, Keyword.fetch!(opts, :run_id)),
      run_id: Keyword.fetch!(opts, :run_id),
      incarnation: Keyword.get(opts, :incarnation, 1),
      authority: Keyword.fetch!(opts, :authority)
    }

    with {:ok, child_binding} <- Goal.delegate(goal, binding, attrs) do
      {:ok,
       opts
       |> Keyword.put(:goal, goal)
       |> Keyword.put(:goal_binding, child_binding)
       |> Keyword.put(:thread_id, child_binding.thread_id)}
    end
  end

  defp attribute_child(opts, _parent), do: {:ok, opts}

  defp carry_limits(opts, run) do
    remaining_work = run.execution_budget.quota - run.execution_budget.used

    with :ok <- remaining_work(remaining_work),
         {:ok, _} <- Execution.validate_limits(opts),
         {:ok, timeout} <- carry_timeout(run.deadline, opts),
         {:ok, _} <- Execution.validate_limits(Keyword.put(opts, :run_timeout, timeout)) do
      {:ok,
       opts
       |> Keyword.put(:work, min(Keyword.get(opts, :work, remaining_work), remaining_work))
       |> Keyword.put(:run_timeout, timeout)
       |> inherit_deadline(run.deadline)}
    end
  end

  defp inherit_deadline(opts, deadline) when is_integer(deadline),
    do: Keyword.put(opts, :inherited_deadline, deadline)

  defp inherit_deadline(opts, :infinity), do: Keyword.delete(opts, :inherited_deadline)

  defp remaining_work(value) when value > 0, do: :ok

  defp remaining_work(_),
    do: {:error, Error.new(:budget_exceeded, "agent work quota is exhausted")}

  defp carry_timeout(:infinity, opts), do: {:ok, Keyword.get(opts, :run_timeout, :infinity)}

  defp carry_timeout(deadline, opts) when is_integer(deadline) do
    remaining = deadline - System.system_time(:millisecond)
    requested = Keyword.get(opts, :run_timeout, :infinity)

    cond do
      remaining <= 0 -> {:error, Error.new(:timeout, "agent deadline has expired")}
      requested == :infinity -> {:ok, remaining}
      is_integer(requested) and requested > 0 -> {:ok, min(requested, remaining)}
      true -> {:error, Error.new(:validation, "invalid replacement run timeout")}
    end
  end

  defp parent_metadata(state, agent) do
    if agent.parent == state.parent_name do
      Map.merge(
        %{
          run_id: state.parent_run_id,
          name: state.parent_name,
          authority: state.parent_authority
        },
        state.root_goal_context
      )
    else
      parent = state.agents[agent.parent]

      Map.merge(
        %{
          run_id: parent.run_id,
          name: parent.name,
          authority: current_child_authority(state, parent)
        },
        Map.take(Map.new(parent.opts), [:goal, :goal_binding])
      )
    end
  end

  defp settled_snapshot(%{snapshot: snapshot, snapshot_identity: identity, run_id: run_id})
       when is_map(snapshot) and is_map(identity) do
    if identity == snapshot_identity(snapshot) and Map.get(identity, :run_id) == run_id,
      do: {:ok, snapshot},
      else: {:error, Error.new(:unknown_outcome, "cached agent snapshot belongs to an older run")}
  end

  defp settled_snapshot(%{pid: pid}) when is_pid(pid) do
    deadline = System.monotonic_time(:millisecond) + @settlement_wait_ms
    await_settlement(pid, deadline)
  end

  defp settled_snapshot(_agent),
    do: {:error, Error.new(:unknown_outcome, "agent snapshot is unavailable")}

  defp snapshot_identity(%{run: run}),
    do: %{run_id: Map.get(run, :run_id), incarnation: Map.get(run, :incarnation)}

  defp await_settlement(pid, deadline) do
    case Conversation.status(pid) do
      %{phase: :terminal} = snapshot ->
        {:ok, snapshot}

      %{phase: :storage_failed} ->
        {:error, Error.new(:unknown_outcome, "agent store settlement is uncertain")}

      %{phase: :recovery_required} ->
        {:error, Error.new(:unknown_outcome, "agent requires host recovery")}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          await_settlement(pid, deadline)
        else
          {:error, Error.new(:unknown_outcome, "agent termination is not settled")}
        end
    end
  catch
    :exit, _ -> {:error, Error.new(:unknown_outcome, "agent snapshot is unavailable")}
  end

  defp safe_replacement(%{run: run, resource_cleanup: :confirmed}) do
    active_tools = Map.get(run, :active_tools, %{})

    cond do
      map_size(active_tools) > 0 ->
        {:error, Error.new(:unknown_outcome, "agent has unreconciled tool effects")}

      run.state == :unknown_outcome and is_nil(Map.get(run, :active_provider)) ->
        {:error, Error.new(:unknown_outcome, "agent has unreconciled execution")}

      # The cancelled provider response is discarded; no tool was dispatched.
      run.state == :unknown_outcome ->
        :ok

      run.state in [:completed, :failed, :cancelled, :timed_out] ->
        :ok

      true ->
        {:error, Error.new(:resource_conflict, "agent run is not settled")}
    end
  end

  defp safe_replacement(_snapshot),
    do: {:error, Error.new(:unknown_outcome, "agent resource cleanup is not confirmed")}

  defp maybe_prompt(_pid, nil), do: :ok

  defp maybe_prompt(pid, message) do
    case Conversation.prompt(pid, message) do
      {:ok, _} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp cancel_agent(%{pid: pid}) when is_pid(pid) do
    case Conversation.cancel(pid) do
      :ok -> :ok
      {:error, %Error{class: :resource_conflict}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  catch
    :exit, _ -> :ok
  end

  defp cancel_agent(%{pid: nil, closure: :confirmed}), do: :already_closed

  defp cancel_agent(%{pid: nil, closure: {:uncertain, _}}),
    do: {:error, Error.new(:unknown_outcome, "agent cleanup is not settled")}

  defp cancel_agent(%{pid: nil, snapshot: snapshot} = agent) when is_map(snapshot) do
    with {:ok, snapshot} <- settled_snapshot(agent), do: safe_replacement(snapshot)
  end

  defp cancel_agent(%{pid: nil}),
    do: {:error, Error.new(:unknown_outcome, "agent process identity is unavailable")}

  defp cancel_agent(_agent),
    do: {:error, Error.new(:unknown_outcome, "agent process identity is unavailable")}

  defp cancel_owned_tree(state, name, action) do
    names = [name | descendant_names(state, name)]
    next_status = if action == :close, do: :shutdown, else: :interrupted

    Enum.reduce_while(names, {:ok, state}, fn child_name, {:ok, acc} ->
      case Map.fetch(acc.agents, child_name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, agent} ->
          if action == :close and agent.closure == :confirmed do
            acc =
              if agent.status != :shutdown and agent.pid == nil and not agent.execution_reserved do
                closed = %{agent | status: :shutdown}

                acc
                |> put_in([:agents, child_name], closed)
                |> Map.update!(:updates, &MapSet.put(&1, child_name))
                |> publish(:closed, child_name)
              else
                acc
              end

            {:cont, {:ok, acc}}
          else
            agent = %{
              agent
              | closure: if(action == :close, do: :in_progress, else: agent.closure)
            }

            acc = put_in(acc, [:agents, child_name], agent)

            case cancel_agent(agent) do
              :ok ->
                case maybe_close_child(acc, agent, action) do
                  {:ok, closed_agent} ->
                    closed_agent = %{closed_agent | status: next_status}
                    acc = put_in(acc, [:agents, child_name], closed_agent)
                    acc = publish(acc, :closed, child_name)

                    {:cont,
                     {:ok,
                      %{
                        acc
                        | monitors: maybe_delete_monitor(acc.monitors, closed_agent.monitor),
                          updates: MapSet.put(acc.updates, child_name)
                      }}}

                  {:error, %Error{} = error} ->
                    uncertain = %{agent | status: :interrupted, closure: {:uncertain, error}}
                    acc = put_in(acc, [:agents, child_name], uncertain)
                    acc = publish(acc, :cleanup_uncertain, child_name)

                    {:halt,
                     {:error, error, %{acc | updates: MapSet.put(acc.updates, child_name)}}}
                end

              :already_closed ->
                {:cont, {:ok, acc}}

              {:error, %Error{} = error} ->
                acc =
                  if action == :close do
                    put_in(acc, [:agents, child_name], %{
                      agent
                      | status: :interrupted,
                        closure: {:uncertain, error}
                    })
                  else
                    acc
                  end

                acc = publish(acc, :cleanup_uncertain, child_name)

                {:halt, {:error, error, acc}}
            end
          end
      end
    end)
  end

  defp maybe_close_child(_state, agent, :interrupt), do: {:ok, agent}

  defp maybe_close_child(state, %{pid: pid} = agent, :close) when is_pid(pid) do
    with {:ok, snapshot} <- settled_snapshot(agent),
         :ok <- safe_demonitor(agent.monitor),
         :ok <- safe_terminate_child(state.child_supervisor, pid) do
      {:ok,
       agent
       |> Map.put(:pid, nil)
       |> Map.put(:monitor, nil)
       |> Map.put(:snapshot, snapshot)
       |> Map.put(:snapshot_identity, snapshot_identity(snapshot))
       |> Map.put(:execution_reserved, safe_replacement(snapshot) != :ok)
       |> Map.put(:closure, :confirmed)}
    end
  end

  defp maybe_close_child(_state, %{pid: nil} = agent, :close) do
    with {:ok, snapshot} <- settled_snapshot(agent),
         do:
           {:ok,
            %{agent | closure: :confirmed, execution_reserved: safe_replacement(snapshot) != :ok}}
  end

  defp safe_demonitor(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  catch
    :error, _ -> :ok
  end

  defp safe_demonitor(_), do: :ok

  defp safe_terminate_child(supervisor, pid) when is_pid(supervisor) and is_pid(pid) do
    if Process.alive?(supervisor) do
      case DynamicSupervisor.terminate_child(supervisor, pid) do
        :ok ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          {:error, Error.new(:unknown_outcome, "agent termination is uncertain", cause: reason)}
      end
    else
      {:error, Error.new(:unknown_outcome, "agent supervisor is unavailable")}
    end
  catch
    :exit, reason ->
      {:error, Error.new(:unknown_outcome, "agent termination is uncertain", cause: reason)}
  end

  defp safe_terminate_child(_supervisor, _pid),
    do: {:error, Error.new(:unknown_outcome, "agent process identity is unavailable")}

  defp maybe_delete_monitor(monitors, ref) when is_reference(ref), do: Map.delete(monitors, ref)
  defp maybe_delete_monitor(monitors, _), do: monitors

  defp descendant_names(state, name) do
    direct =
      state.agents
      |> Enum.filter(fn {_child_name, agent} -> agent.parent == name end)
      |> Enum.map(&elem(&1, 0))

    direct ++ Enum.flat_map(direct, &descendant_names(state, &1))
  end

  defp transfer_snapshot(%{snapshot: snapshot}) when is_map(snapshot), do: {:ok, snapshot}

  defp transfer_snapshot(%{pid: pid}) when is_pid(pid) do
    snapshot = Conversation.status(pid)

    if snapshot.phase in [:storage_failed, :recovery_required],
      do: {:error, Error.new(:unknown_outcome, "child requires reconciliation")},
      else: {:ok, snapshot}
  catch
    :exit, reason ->
      {:error, Error.new(:unknown_outcome, "child state is unavailable", cause: reason)}
  end

  defp transfer_snapshot(_),
    do: {:error, Error.new(:unknown_outcome, "child state is unavailable")}

  defp authenticate(%{run_id: run_id} = operation, state) do
    cond do
      state.session_closed ->
        {:error, Error.new(:forbidden, "collaboration session is closed")}

      run_id == state.parent_run_id ->
        if current_parent?(state, operation) do
          {:ok,
           %{
             name: state.parent_name,
             agent_id: state.root_id,
             incarnation: state.parent_incarnation,
             run_id: state.parent_run_id,
             authority: current_root_authority(state, operation),
             goal: get_in(operation, [:backend_context, :goal]),
             goal_binding: get_in(operation, [:backend_context, :goal_binding])
           }}
        else
          {:error, Error.new(:forbidden, "stale collaboration parent invocation")}
        end

      name = state.run_index[run_id] ->
        agent = state.agents[name]

        if agent.run_id == run_id and agent.status == :running,
          do:
            {:ok,
             %{
               name: name,
               agent_id: agent.id,
               incarnation: agent.incarnation,
               run_id: run_id,
               authority: current_child_authority(state, agent),
               goal: Keyword.get(agent.opts, :goal),
               goal_binding: Keyword.get(agent.opts, :goal_binding)
             }},
          else: {:error, Error.new(:forbidden, "stale collaboration run")}

      true ->
        {:error, Error.new(:forbidden, "collaboration caller is not in this run tree")}
    end
  end

  defp authenticate(_, _state),
    do: {:error, Error.new(:forbidden, "collaboration caller is missing")}

  defp current_parent?(%{session_owner: nil}, _operation), do: true

  defp current_parent?(%{parent_binding: binding}, operation) when is_map(binding) do
    owner = get_in(operation, [:backend_context, :resource_owner])

    operation[:incarnation] == binding.run_incarnation and is_map(owner) and
      owner[:owner_id] == binding.owner_id and owner[:incarnation] == binding.incarnation
  end

  defp current_parent?(_, _), do: false

  defp current_root_authority(%{session_owner: nil} = state, _operation),
    do: state.parent_authority

  defp current_root_authority(state, operation) do
    case operation[:effective_authority] do
      current when is_map(current) ->
        if state.session_authority do
          allowed = MapSet.new(Map.get(state.session_authority, :grants, []))
          grants = Enum.filter(Map.get(current, :grants, []), &MapSet.member?(allowed, &1))
          Map.put(current, :grants, grants)
        else
          current
        end

      _ ->
        state.parent_authority
    end
  end

  defp current_child_authority(%{session_owner: nil}, agent), do: agent.authority

  defp current_child_authority(state, agent) do
    allowed = MapSet.new(Map.get(state.parent_authority, :grants, []))
    grants = Enum.filter(Map.get(agent.authority, :grants, []), &MapSet.member?(allowed, &1))
    Map.put(agent.authority, :grants, grants)
  end

  defp action(:v2, name) do
    case name do
      "spawn_agent" -> {:ok, {:spawn, :v2}}
      "send_message" -> {:ok, :message}
      "followup_task" -> {:ok, :followup_v2}
      "interrupt_agent" -> {:ok, :interrupt}
      "list_agents" -> {:ok, :list}
      "wait_agent" -> {:ok, :wait_v2}
      _ -> {:error, Error.new(:not_found, "unknown V2 collaboration tool")}
    end
  end

  defp action(:v1, @v1_namespace <> "::spawn_agent"), do: {:ok, {:spawn, :v1}}
  defp action(:v1, @v1_namespace <> "::send_input"), do: {:ok, :send_input}
  defp action(:v1, @v1_namespace <> "::resume_agent"), do: {:ok, :resume}
  defp action(:v1, @v1_namespace <> "::wait_agent"), do: {:ok, :wait_v1}
  defp action(:v1, @v1_namespace <> "::close_agent"), do: {:ok, :close}
  defp action(:v1, _), do: {:error, Error.new(:not_found, "unknown V1 collaboration tool")}

  defp spawn_request(arguments, profile) do
    message = arguments["message"] || input_items_text(arguments["items"])
    task_name = arguments["task_name"] || unique_id("agent")

    with true <-
           (is_binary(message) and String.trim(message) != "") or
             validation("message is required"),
         :ok <- validate_task_name(task_name, profile) do
      {:ok, %{profile: profile, message: message, task_name: task_name, options: arguments}}
    end
  end

  defp validate_task_name(name, :v2) when is_binary(name) do
    if Regex.match?(~r/^[a-z0-9_]+$/, name), do: :ok, else: validation("invalid task_name")
  end

  defp validate_task_name(name, :v1) when is_binary(name) and name != "", do: :ok
  defp validate_task_name(_, _), do: validation("invalid task_name")

  defp child_name(caller, task_name), do: {:ok, caller.name <> "/" <> task_name}
  defp child_run_id(name, sequence), do: name <> ":" <> Integer.to_string(sequence)

  defp start_child(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {Conversation, opts})
  end

  defp child_authority(opts, parent_authority) do
    child = Keyword.get(opts, :authority, %{})
    parent_grants = MapSet.new(Map.get(parent_authority, :grants, []))
    child_grants = MapSet.new(Map.get(child, :grants, []))

    if MapSet.subset?(child_grants, parent_grants),
      do: :ok,
      else: {:error, Error.new(:forbidden, "child authority exceeds parent grants")}
  end

  defp prepare_activation(state, profile, replacing \\ nil)

  defp prepare_activation(state, :v1, replacing) when is_binary(replacing), do: {:ok, state}

  defp prepare_activation(state, :v1, _replacing) do
    case capacity(state) do
      :ok -> {:ok, state}
      {:error, error} -> {:refused, error, state}
    end
  end

  defp prepare_activation(state, :v2, replacing) do
    reserved =
      Enum.count(state.agents, fn {name, agent} ->
        name != replacing and Map.get(agent, :execution_reserved, agent.status != :shutdown)
      end)

    # Only this check precedes residency eviction and every admission callback.
    if reserved >= state.v2_child_limit do
      {:refused, Error.new(:resource_conflict, "agent execution limit reached"), state}
    else
      make_resident_room(state, replacing)
    end
  end

  defp make_resident_room(state, replacing) do
    residents = Enum.count(state.agents, fn {_name, agent} -> is_pid(agent.pid) end)

    if residents < state.v2_child_limit do
      {:ok, state}
    else
      candidate =
        Enum.find(state.agents, fn {name, agent} ->
          is_pid(agent.pid) and (name == replacing or not agent.execution_reserved)
        end)

      case candidate do
        nil ->
          {:error, Error.new(:resource_conflict, "agent residency limit reached"), state}

        {name, agent} ->
          with {:ok, snapshot} <- settled_snapshot(agent),
               :ok <- safe_replacement(snapshot),
               :ok <- safe_terminate_child(state.child_supervisor, agent.pid) do
            safe_demonitor(agent.monitor)

            unloaded = %{
              agent
              | pid: nil,
                monitor: nil,
                snapshot: snapshot,
                snapshot_identity: snapshot_identity(snapshot)
            }

            next =
              state
              |> put_in([:agents, name], unloaded)
              |> Map.update!(:monitors, &Map.delete(&1, agent.monitor))
              |> publish(:unloaded, name)

            make_resident_room(next, replacing)
          else
            {:error, error} -> {:error, error, reserve_uncertain(state, name, error)}
          end
      end
    end
  end

  defp settle_v2_agent(state, name) do
    agent = state.agents[name]

    with {:ok, snapshot} <- settled_snapshot(agent),
         :ok <- safe_replacement(snapshot) do
      settled = %{
        agent
        | snapshot: snapshot,
          snapshot_identity: snapshot_identity(snapshot),
          execution_reserved: false
      }

      put_in(state, [:agents, name], settled)
    else
      {:error, error} -> reserve_uncertain(state, name, error)
    end
  end

  defp reserve_uncertain(state, name, error) do
    agent = state.agents[name]

    put_in(state, [:agents, name], %{
      agent
      | execution_reserved: true,
        closure: {:uncertain, error},
        snapshot: nil,
        snapshot_identity: nil
    })
    |> publish(:cleanup_uncertain, name)
  end

  defp reject_interrupt_target(state, caller, target) do
    if target in [state.parent_name, state.parent_run_id, caller.name, caller.run_id],
      do: {:error, Error.new(:forbidden, "root and self interruption is not allowed")},
      else: :ok
  end

  defp interrupt_target(state, name, agent) do
    if agent.execution_reserved do
      with :ok <- cancel_agent(agent),
           {:ok, snapshot} <- settled_snapshot(agent),
           :ok <- safe_replacement(snapshot) do
        interrupted = %{
          agent
          | status: :interrupted,
            execution_reserved: false,
            snapshot: snapshot,
            snapshot_identity: snapshot_identity(snapshot)
        }

        next =
          state
          |> put_in([:agents, name], interrupted)
          |> Map.update!(:updates, &MapSet.put(&1, name))
          |> publish(:interrupted, name)

        {:ok, next}
      else
        {:error, error} -> {:error, error, reserve_uncertain(state, name, error)}
      end
    else
      {:ok, state}
    end
  end

  defp capacity(state) do
    live = Enum.count(state.agents, fn {_name, agent} -> agent.status != :shutdown end)

    if live < state.max_agents,
      do: :ok,
      else: {:error, Error.new(:resource_conflict, "agent limit reached")}
  end

  defp unique_name(state, name) do
    if Map.has_key?(state.agents, name),
      do: validation("task_name is already in use"),
      else: :ok
  end

  defp resolve_targets(state, targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, names} ->
      case resolve_target(state, target) do
        {:ok, name, _agent} -> {:cont, {:ok, [name | names]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      error -> error
    end
  end

  defp resolve_target(state, target) when is_binary(target) do
    name =
      cond do
        Map.has_key?(state.agents, target) -> target
        Map.has_key?(state.run_index, target) -> state.run_index[target]
        String.starts_with?(target, "/") -> target
        true -> state.parent_name <> "/" <> target
      end

    case Map.fetch(state.agents, name) do
      {:ok, agent} -> {:ok, name, agent}
      :error -> {:error, Error.new(:not_found, "agent was not found")}
    end
  end

  defp resolve_target(_state, _target), do: {:error, Error.new(:validation, "target is required")}

  defp ready_names(state, nil), do: MapSet.to_list(state.updates)

  defp ready_names(state, names) do
    Enum.filter(names, fn name ->
      MapSet.member?(state.updates, name) or terminal_status?(state.agents[name].status)
    end)
  end

  defp terminal_status?(status),
    do: status == :completed or status == :shutdown or match?({:errored, _}, status)

  defp consume_updates(state, names),
    do: %{state | updates: Enum.reduce(names, state.updates, &MapSet.delete(&2, &1))}

  defp reject_wait_cycle(:v2, _caller, _names, _state), do: :ok

  defp reject_wait_cycle(:v1, caller, names, state) do
    graph =
      state.waiters
      |> Map.values()
      |> Enum.filter(&(&1.profile == :v1))
      |> Enum.reduce(%{}, fn waiter, acc ->
        Map.update(
          acc,
          waiter.caller,
          MapSet.new(waiter.names),
          &MapSet.union(&1, MapSet.new(waiter.names))
        )
      end)
      |> Map.update(caller, MapSet.new(names), &MapSet.union(&1, MapSet.new(names)))

    if Enum.any?(names, &(&1 == caller or reachable?(graph, &1, caller, MapSet.new()))),
      do:
        {:error,
         Error.new(:resource_conflict, "collaboration wait would create a dependency cycle")},
      else: :ok
  end

  defp reachable?(_graph, node, target, _visited) when node == target, do: true

  defp reachable?(graph, node, target, visited) do
    if MapSet.member?(visited, node) do
      false
    else
      graph
      |> Map.get(node, MapSet.new())
      |> Enum.any?(&reachable?(graph, &1, target, MapSet.put(visited, node)))
    end
  end

  defp v1_wait_result(state, names) do
    status =
      Map.new(names, fn name -> {state.agents[name].id, public_status(state.agents[name])} end)

    %{status: status, timed_out: false}
  end

  defp v2_wait_result(activity) do
    %{
      message:
        if(activity == :steer, do: "Wait interrupted by new input.", else: "Wait completed."),
      timed_out: false
    }
  end

  defp public_status(%{status: :completed, final: final}), do: %{completed: final}

  defp public_status(%{closure: {:uncertain, %Error{message: message}}}) do
    %{unknown_outcome: message || "agent cleanup is not settled"}
  end

  defp public_status(%{status: {:errored, reason}}), do: %{errored: reason}

  defp public_status(%{status: status}) when status in [:running, :interrupted, :shutdown],
    do: status

  defp public_status(_), do: :pending_init

  defp wait_timeout(nil, state), do: {:ok, state.default_wait_timeout_ms}

  defp wait_timeout(value, state) when is_integer(value) do
    if value >= state.min_wait_timeout_ms and value <= state.max_wait_timeout_ms,
      do: {:ok, value},
      else: {:error, Error.new(:validation, "timeout_ms is outside the configured bounds")}
  end

  defp wait_timeout(_, _state),
    do: {:error, Error.new(:validation, "timeout_ms must be an integer")}

  defp input_items_text(items) when is_list(items) do
    items
    |> Enum.map_join("\n", fn item -> item["text"] || item[:text] || inspect(item) end)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp input_items_text(_), do: nil

  defp communication(source, kind, result_id) do
    %{
      kind: kind,
      result_id: result_id,
      source_name: source.name,
      source_agent_id: source.agent_id,
      source_run_id: source.run_id,
      source_incarnation: source.incarnation
    }
  end

  defp mailbox_destination(state, target) do
    if target in [state.parent_name, state.parent_run_id] do
      if state.parent_recovery do
        {:error, Error.new(:unknown_outcome, "parent input requires recovery")}
      else
        {:ok, state.parent_name,
         %{
           pid: state.parent_pid,
           identity: %{
             run_id: state.parent_run_id,
             incarnation: state.parent_incarnation,
             session_binding: state.parent_binding
           }
         }}
      end
    else
      with {:ok, name, agent} <- resolve_target(state, target) do
        cond do
          agent.status == :shutdown ->
            {:error, Error.new(:forbidden, "mailbox destination is closed")}

          match?({:uncertain, _}, agent.closure) ->
            {:error, Error.new(:unknown_outcome, "mailbox destination requires recovery")}

          agent.status == :running ->
            {:ok, name,
             %{
               pid: agent.pid,
               identity: %{
                 run_id: agent.run_id,
                 incarnation: agent.incarnation,
                 session_binding: Keyword.get(agent.opts, :session_binding)
               }
             }}

          true ->
            with {:ok, snapshot} <- settled_snapshot(agent),
                 :ok <- safe_replacement(snapshot),
                 do: {:ok, name, %{pid: nil}}
        end
      end
    end
  end

  defp communication_text(destination, content, envelope) do
    type = if envelope.kind == :result, do: "FINAL_ANSWER", else: "MESSAGE"

    "Message Type: " <>
      type <>
      "\nTask name: " <>
      destination <>
      "\nSender: " <> envelope.source_name <> "\nPayload:\n" <> content
  end

  defp queue_message(state, name, %{pid: nil}, content, envelope, from, source) do
    content = communication_text(name, content, envelope)
    message = %{role: :user, content: content, id: envelope.result_id, collaboration: envelope}
    entries = Map.get(state.mailboxes, name, [])

    entries =
      if Enum.any?(entries, &(&1.id == message.id)), do: entries, else: entries ++ [message]

    next =
      %{state | mailboxes: Map.put(state.mailboxes, name, entries)}
      |> change_input_activity(name, :mailbox)
      |> wake_waiters()

    receipt = %{accepted: true, message_id: message.id, acceptance: :process_local}

    if from,
      do: {:reply, {:ok, receipt}, next},
      else: {:noreply, record_result_delivery(next, source, {:ok, receipt})}
  end

  defp queue_message(state, name, destination, content, envelope, from, source) do
    owner = self()
    token = make_ref()

    worker =
      spawn(fn ->
        result =
          try do
            Conversation.queue_only(
              destination.pid,
              communication_text(name, content, envelope),
              envelope,
              destination.identity
            )
          rescue
            _ -> {:error, Error.new(:execution_failure, "mailbox delivery failed")}
          catch
            :exit, _ ->
              {:error, Error.new(:unknown_outcome, "mailbox destination is unavailable")}
          end

        send(owner, {:mail_delivery, token, result})
      end)

    timer = Process.send_after(self(), {:mail_delivery_timeout, token}, 5_000)

    entry = %{
      worker: worker,
      timer: timer,
      from: from,
      source: source,
      name: name,
      destination: destination
    }

    {:noreply, %{state | deliveries: Map.put(state.deliveries, token, entry)}}
  end

  defp complete_delivery(state, token, result) do
    case Map.pop(state.deliveries, token) do
      {nil, _} ->
        state

      {entry, deliveries} ->
        Process.cancel_timer(entry.timer)
        next = %{state | deliveries: deliveries}

        if entry.from do
          response =
            case result do
              {:ok, receipt} -> {:ok, Map.put(receipt, :accepted, true)}
              {:error, error} -> {:error, error}
            end

          GenServer.reply(entry.from, response)
        end

        record_result_delivery(next, entry.source, result)
    end
  end

  defp deliver_terminal_result(state, name) do
    agent = state.agents[name]
    result_id = "result:" <> agent.run_id <> ":" <> Integer.to_string(agent.incarnation)

    if agent.profile != :v2 or agent.status == :interrupted or
         match?(
           %{result_id: ^result_id, status: status} when status in [:pending, :accepted],
           Map.get(agent, :result_delivery)
         ) do
      state
    else
      source = %{
        name: name,
        run_id: agent.run_id,
        incarnation: agent.incarnation,
        result_id: result_id
      }

      next =
        put_in(
          state,
          [:agents, name],
          Map.put(agent, :result_delivery, %{
            result_id: result_id,
            status: :pending,
            error_class: nil
          })
        )
        |> publish(:result_delivery_pending, name)

      case mailbox_destination(next, agent.parent) do
        {:ok, parent, destination} ->
          envelope =
            communication(
              %{
                name: name,
                agent_id: agent.id,
                run_id: agent.run_id,
                incarnation: agent.incarnation
              },
              :result,
              result_id
            )

          content =
            case agent.status do
              :completed ->
                "Agent " <> name <> " completed: " <> terminal_text(agent.final)

              {:errored, reason} ->
                "Agent " <> name <> " errored: " <> to_string(reason)

              :shutdown ->
                "Agent " <> name <> " was shut down."
            end

          case queue_message(next, parent, destination, content, envelope, nil, source) do
            {:noreply, queued} -> queued
          end

        {:error, error} ->
          record_result_delivery(next, source, {:error, error})
      end
    end
  end

  defp terminal_text(nil), do: "No final message."
  defp terminal_text(content) when is_binary(content), do: content

  defp terminal_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      text when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      block -> inspect(block)
    end)
  end

  defp terminal_text(content), do: inspect(content)

  defp record_result_delivery(state, nil, _result), do: state

  defp record_result_delivery(state, source, result) do
    agent = state.agents[source.name]

    if agent.run_id == source.run_id and agent.incarnation == source.incarnation do
      record =
        case result do
          {:ok, receipt} ->
            %{
              result_id: source.result_id,
              status: :accepted,
              error_class: nil,
              acceptance: receipt[:acceptance] || :checkpointed
            }

          {:error, error} ->
            %{result_id: source.result_id, status: :failed, error_class: error.class}
        end

      type = if record.status == :accepted, do: :result_delivered, else: :result_delivery_failed

      state
      |> put_in([:agents, source.name], Map.put(agent, :result_delivery, record))
      |> publish(type, source.name)
    else
      state
    end
  end

  defp input_owner(state, pid, identity) do
    cond do
      state.session_closed ->
        nil

      pid == state.parent_pid and identity.run_id == state.parent_run_id and
        identity.incarnation == state.parent_incarnation and
          identity.session_binding == state.parent_binding ->
        state.parent_name

      name = state.run_index[identity.run_id] ->
        agent = state.agents[name]

        if agent.pid == pid and agent.run_id == identity.run_id and
             agent.incarnation == identity.incarnation and
             Keyword.get(agent.opts, :session_binding) == identity.session_binding,
           do: name,
           else: nil

      true ->
        nil
    end
  end

  defp reset_input_activity(state, name, carried_mailbox \\ []) do
    pending =
      if carried_mailbox != [] or Map.get(state.mailboxes, name, []) != [],
        do: MapSet.new([:mailbox]),
        else: MapSet.new()

    %{state | input_activity: Map.put(state.input_activity, name, pending)}
  end

  defp change_input_activity(state, name, activity) do
    pending = Map.get(state.input_activity, name, MapSet.new())

    pending =
      case activity do
        :mailbox_consumed -> MapSet.delete(pending, :mailbox)
        :steer_consumed -> MapSet.delete(pending, :steer)
        other -> MapSet.put(pending, other)
      end

    %{state | input_activity: Map.put(state.input_activity, name, pending)}
  end

  defp caller_activity(state, name) do
    pending = Map.get(state.input_activity, name, MapSet.new())

    cond do
      MapSet.member?(pending, :steer) -> :steer
      MapSet.member?(pending, :mailbox) -> :mailbox
      true -> nil
    end
  end

  defp caller_metadata(caller),
    do: Map.take(caller, [:run_id, :name, :authority, :goal, :goal_binding])

  defp event_error(event), do: inspect(Map.get(event, :outcome, "agent stopped"))

  defp reserve_admission(state, attrs) do
    sequence = state.sequence + 1
    run_id = child_run_id(attrs.name, sequence)

    attempt =
      Map.merge(attrs, %{
        attempt_id: state.manager_id <> ":" <> Integer.to_string(sequence),
        manager_id: state.manager_id,
        sequence: sequence,
        run_id: run_id,
        agent_id: Map.get(attrs, :agent_id, run_id),
        status: :reserved,
        process_started: false,
        error_class: nil,
        reason: nil,
        receipt_acknowledged: nil,
        receipt_error_class: nil
      })

    next = %{
      state
      | sequence: sequence,
        admissions: Map.put(state.admissions, attempt.attempt_id, attempt)
    }

    {publish_admission(next, attempt), attempt}
  end

  defp admission_child(attempt),
    do: Map.take(attempt, [:attempt_id, :agent_id, :name, :run_id, :incarnation, :activation])

  defp record_admission(state, attempt, status, error) do
    latest = Map.fetch!(state.admissions, attempt.attempt_id)

    receipt = %{
      latest
      | status: status,
        process_started: latest.process_started or status == :created,
        receipt_acknowledged: nil,
        receipt_error_class: nil,
        error_class: if(error, do: error.class),
        reason: if(error, do: "child_admission_failed")
    }

    acknowledgement =
      if state.admission_receipt,
        do:
          admission_operation(fn ->
            receipt_acknowledgement(state.admission_receipt.(receipt))
          end),
        else: :ok

    acknowledged = if state.admission_receipt, do: acknowledgement == :ok

    receipt_error =
      case acknowledgement do
        :ok -> nil
        {:error, callback_error} -> callback_error.class
      end

    receipt = %{receipt | receipt_acknowledged: acknowledged, receipt_error_class: receipt_error}

    next =
      %{state | admissions: Map.put(state.admissions, attempt.attempt_id, receipt)}
      |> publish_admission(receipt)

    case acknowledgement do
      :ok -> {:ok, next}
      {:error, callback_error} -> {:error, callback_error, next}
    end
  end

  defp receipt_acknowledgement(:ok), do: :ok
  defp receipt_acknowledgement({:error, %Error{}} = error), do: error

  defp receipt_acknowledgement(_),
    do: validation("admission receipt callback returned an invalid acknowledgement")

  defp reject_admission(state, attempt, status, error) do
    next =
      case record_admission(state, attempt, status, error) do
        {:ok, next} -> next
        {:error, _callback_error, next} -> next
      end

    details = if is_map(error.details), do: error.details, else: %{}

    error = %{
      error
      | details:
          Map.merge(details, %{attempt_id: attempt.attempt_id, manager_id: attempt.manager_id})
    }

    {error, next}
  end

  defp publish_admission(state, receipt) do
    next = %{state | revision: state.revision + 1}

    type =
      case receipt.status do
        :reserved -> :admission_reserved
        :created -> :admission_created
        :rejected -> :admission_rejected
        :failed -> :admission_failed
      end

    event = %{
      manager_id: next.manager_id,
      revision: next.revision,
      type: type,
      admission: receipt
    }

    recipients = Map.keys(next.observers)
    recipients = if is_pid(next.subscriber), do: [next.subscriber | recipients], else: recipients
    Enum.each(Enum.uniq(recipients), &send(&1, {:codex_collaboration, event}))
    next
  end

  defp public_snapshot(state) do
    %{
      schema_version: 1,
      manager_id: state.manager_id,
      revision: state.revision,
      root_name: state.parent_name,
      admissions: state.admissions |> Map.values() |> Enum.sort_by(& &1.sequence),
      agents:
        state.agents
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&public_agent(state, &1))
    }
  end

  defp child_limit(opts) do
    max_agents = Keyword.get(opts, :max_agents, 16)
    total = Keyword.get(opts, :max_concurrent_threads_per_session)

    cond do
      not is_integer(max_agents) or max_agents < 1 ->
        {:error, Error.new(:validation, "max_agents must be a positive integer")}

      total != nil and (not is_integer(total) or total < 1) ->
        {:error,
         Error.new(:validation, "max_concurrent_threads_per_session must be a positive integer")}

      total != nil ->
        {:ok, total - 1}

      Keyword.has_key?(opts, :max_agents) ->
        {:ok, max_agents}

      true ->
        {:ok, 3}
    end
  end

  defp public_agent(_state, agent) do
    uncertain =
      match?({:uncertain, _}, agent.closure) or
        (is_map(agent.snapshot) and safe_replacement(agent.snapshot) != :ok)

    status =
      cond do
        uncertain -> :unknown_outcome
        agent.status == :shutdown -> :closed
        match?({:errored, _}, agent.status) -> :errored
        true -> agent.status
      end

    cleanup =
      cond do
        uncertain -> :uncertain
        agent.closure == :confirmed -> :confirmed
        is_map(agent.snapshot) and agent.snapshot.resource_cleanup == :confirmed -> :confirmed
        true -> :pending
      end

    reason =
      case status do
        :unknown_outcome -> "cleanup_unconfirmed"
        :errored -> "execution_failed"
        _ -> nil
      end

    %{
      agent_id: agent.id,
      attempt_id: agent.attempt_id,
      name: agent.name,
      task_name: agent.name,
      parent_id: agent.parent_id,
      parent_name: agent.parent,
      profile: agent.profile,
      run_id: agent.run_id,
      incarnation: agent.incarnation,
      status: status,
      reason: reason,
      cleanup: cleanup,
      resident: is_pid(agent.pid),
      host_metadata: agent.host_metadata,
      result_delivery: Map.get(agent, :result_delivery)
    }
  end

  defp publish(state, type, name) do
    next = %{state | revision: state.revision + 1}

    event = %{
      manager_id: next.manager_id,
      revision: next.revision,
      type: type,
      agent: public_agent(next, next.agents[name])
    }

    recipients = Map.keys(next.observers)
    recipients = if is_pid(next.subscriber), do: [next.subscriber | recipients], else: recipients
    Enum.each(Enum.uniq(recipients), &send(&1, {:codex_collaboration, event}))
    next
  end

  defp normalize_root("/" <> _ = name), do: String.trim_trailing(name, "/")
  defp normalize_root(name), do: "/" <> String.trim(name, "/")

  defp required_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} is required")}
    end
  end

  defp required_map(opts, key) do
    case Keyword.get(opts, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} is required")}
    end
  end

  defp optional_callback(opts, key, arity) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      callback when is_function(callback, arity) -> {:ok, callback}
      _ -> validation("#{key} must be a callback with arity #{arity}")
    end
  end

  defp required_callback(opts, key, arity) do
    case Keyword.get(opts, key) do
      value when is_function(value, arity) -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} callback is required")}
    end
  end

  defp unique_id(prefix),
    do: prefix <> "_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp validation(message), do: {:error, Error.new(:validation, message)}

  defp v1_contracts(runtime, wait) do
    [
      contract(
        @v1_namespace,
        "spawn_agent",
        "Spawn a new agent.",
        spawn_schema(:v1),
        runtime,
        :v1
      ),
      contract(
        @v1_namespace,
        "send_input",
        "Send input to an existing agent.",
        send_input_schema(),
        runtime,
        :v1
      ),
      contract(
        @v1_namespace,
        "resume_agent",
        "Resume a previously closed agent.",
        required_string_schema("id"),
        runtime,
        :v1
      ),
      contract(
        @v1_namespace,
        "wait_agent",
        "Wait for agents to reach a final status.",
        wait_schema(:v1, wait),
        runtime,
        :v1
      ),
      contract(
        @v1_namespace,
        "close_agent",
        "Close an agent and its owned descendants.",
        required_string_schema("target"),
        runtime,
        :v1
      )
    ]
  end

  defp v2_contracts(runtime, wait) do
    [
      contract(
        nil,
        "spawn_agent",
        "Spawn an agent to work on the specified task.",
        spawn_schema(:v2),
        runtime,
        :v2
      ),
      contract(
        nil,
        "send_message",
        "Send a message to an existing agent without triggering a new turn.",
        target_message_schema(),
        runtime,
        :v2
      ),
      contract(
        nil,
        "followup_task",
        "Send a follow-up task to an existing non-root agent.",
        target_message_schema(),
        runtime,
        :v2
      ),
      contract(
        nil,
        "interrupt_agent",
        "Interrupt an agent's current turn.",
        required_string_schema("target"),
        runtime,
        :v2
      ),
      contract(
        nil,
        "list_agents",
        "List live agents in the current root thread tree.",
        optional_string_schema("path_prefix"),
        runtime,
        :v2
      ),
      contract(
        nil,
        "wait_agent",
        "Wait for a mailbox update from any live agent.",
        wait_schema(:v2, wait),
        runtime,
        :v2
      )
    ]
  end

  defp contract(namespace, name, description, schema, runtime, profile) do
    %{
      namespace: namespace,
      name: name,
      description: description,
      schema: schema,
      backend: Backplane.AgentRuntime.Codex.Backend,
      backend_context: %{family: :collaboration, runtime: runtime, profile: profile},
      revision: 1,
      strict: false,
      safety: %{
        read_only: name in ["list_agents", "wait_agent"],
        retry_safe: false,
        parallel_safe: false
      }
    }
  end

  defp spawn_schema(:v2) do
    object_schema(
      %{
        "task_name" => %{"type" => "string"},
        "message" => %{"type" => "string"},
        "agent_type" => %{"type" => "string"},
        "fork_turns" => %{"type" => "string"},
        "model" => %{"type" => "string"},
        "reasoning_effort" => %{"type" => "string"}
      },
      ["task_name", "message"]
    )
  end

  defp spawn_schema(:v1) do
    object_schema(
      %{
        "message" => %{"type" => "string"},
        "items" => %{"type" => "array", "items" => %{"type" => "object"}},
        "agent_type" => %{"type" => "string"},
        "fork_context" => %{"type" => "boolean"},
        "model" => %{"type" => "string"},
        "reasoning_effort" => %{"type" => "string"}
      },
      []
    )
  end

  defp send_input_schema do
    object_schema(
      %{
        "target" => %{"type" => "string"},
        "message" => %{"type" => "string"},
        "items" => %{"type" => "array", "items" => %{"type" => "object"}},
        "interrupt" => %{"type" => "boolean"}
      },
      ["target"]
    )
  end

  defp target_message_schema,
    do:
      object_schema(%{"target" => %{"type" => "string"}, "message" => %{"type" => "string"}}, [
        "target",
        "message"
      ])

  defp required_string_schema(name), do: object_schema(%{name => %{"type" => "string"}}, [name])
  defp optional_string_schema(name), do: object_schema(%{name => %{"type" => "string"}}, [])

  defp wait_schema(:v1, wait) do
    object_schema(
      %{
        "targets" => %{"type" => "array", "items" => %{"type" => "string"}},
        "timeout_ms" => timeout_schema(wait)
      },
      ["targets"]
    )
  end

  defp wait_schema(:v2, wait), do: object_schema(%{"timeout_ms" => timeout_schema(wait)}, [])

  defp timeout_schema(wait),
    do: %{
      "type" => "integer",
      "minimum" => wait.min,
      "maximum" => wait.max,
      "default" => wait.default
    }

  defp object_schema(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
end
