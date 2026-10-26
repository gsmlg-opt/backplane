defmodule Backplane.AgentRuntime.Codex.MultiAgent do
  @moduledoc """
  Supervised Codex V1/V2 collaboration runtime.

  The process owns only collaboration state and waiters. Child work is executed by
  real `Conversation` processes under a `DynamicSupervisor`.
  """

  use GenServer

  alias Backplane.AgentRuntime.{Conversation, Error, Goal, InputSchema, Policy, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{CollaborationBinding, Contract, Session}

  alias Backplane.AgentRuntime.Execution

  @default_wait_timeout_ms 30_000
  @maximum_wait_timeout_ms 3_600_000
  @settlement_wait_ms 5_000
  @settlement_stages_per_target 4
  @v1_namespace "multi_agent_v1"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def rebind_parent(runtime, binding, authority, catalog_revision \\ 1),
    do: GenServer.call(runtime, {:rebind_parent, binding, authority, catalog_revision})

  @doc false
  def authorize_managed_tool(runtime, identity, descriptor, invocation),
    do:
      GenServer.call(
        runtime,
        {:authorize_managed_tool, identity, descriptor, invocation},
        :infinity
      )

  @doc false
  def adopt_catalog(runtime, binding, expected, catalog),
    do: GenServer.call(runtime, {:adopt_catalog, binding, expected, catalog}, :infinity)

  def detach_parent(runtime, binding), do: GenServer.call(runtime, {:detach_parent, binding})
  def transfer_ready(runtime), do: GenServer.call(runtime, :transfer_ready)
  def close_session(runtime), do: GenServer.call(runtime, :close_session, :infinity)

  def close_session(runtime, owner_id, incarnation),
    do: GenServer.call(runtime, {:close_session, {owner_id, incarnation}}, :infinity)

  @doc """
  Resolves an observed child interaction after its checkpoint is acknowledged.

  Correlation must come from the current manager snapshot or observation stream.
  An unknown outcome must be reconciled through observation, never retried.
  """
  def resolve_interaction(runtime, correlation, value),
    do: GenServer.call(runtime, {:resolve_interaction, correlation, value}, :infinity)

  @doc """
  Cancels only the current child interaction identified by the exact correlation.

  Success acknowledges terminal persistence and confirmed resource settlement.
  The reason is diagnostic text (at most 1024 bytes), not a stop policy. An
  unknown outcome must be reconciled through observation, never retried.
  """
  def cancel_interaction(runtime, correlation, reason),
    do: GenServer.call(runtime, {:cancel_interaction, correlation, reason}, :infinity)

  @doc """
  Sends a bounded notification only to an expected live recipient turn.

  `sender` is the trusted Runtime operation (including incarnation and Session
  resource owner). `recipient` is an identity from this manager's snapshot and
  includes manager_id, agent_id, run_id and incarnation. `notification` contains
  stable id, text and optional serializable metadata. Skips never enter mailboxes;
  ambiguous delivery is an error and must be reconciled rather than retried.
  """
  def notify_active(runtime, sender, recipient, notification),
    do: GenServer.call(runtime, {:notify_active, sender, recipient, notification}, :infinity)

  def snapshot(runtime), do: GenServer.call(runtime, :snapshot)
  def subscribe(runtime, observer \\ self()), do: GenServer.call(runtime, {:subscribe, observer})

  def unsubscribe(runtime, observer \\ self()),
    do: GenServer.call(runtime, {:unsubscribe, observer})

  @doc """
  Binds a normalized host contract to one collaboration action in this manager.

  The returned contract does not grant authority. Hosts must explicitly grant its
  name, revision and `collaboration_binding.fingerprint` in `tool_bindings`.
  Argument/result conversion belongs to its trusted registered backend.
  """
  @spec bind_contract(pid(), atom(), map()) :: {:ok, Contract.t()} | {:error, Error.t()}
  def bind_contract(runtime, action, attrs) when is_pid(runtime) do
    with true <-
           action in CollaborationBinding.actions() or validation("invalid collaboration action"),
         {:ok, contract} <- Contract.new(attrs),
         true <-
           not is_nil(contract.backend) or
             validation("bound collaboration requires a host backend") do
      GenServer.call(runtime, {:bind_contract, action, contract})
    end
  end

  @doc """
  Executes an admitted host invocation using its immutable collaboration binding.

  The original invocation and arguments remain the effect/refusal identity;
  `canonical_arguments` are separately converted by the trusted host adapter.
  """
  @spec call_bound(map(), map()) :: ToolEffects.result()
  def call_bound(%{backend_context: %{runtime: runtime}} = operation, canonical_arguments)
      when is_pid(runtime) do
    with {:ok, owner} <- bound_owner(operation) do
      GenServer.call(runtime, {:bound_tool, operation, canonical_arguments, owner}, :infinity)
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
    end
  catch
    :exit, reason ->
      {:error,
       Error.new(:execution_failure, "collaboration runtime is unavailable", cause: reason)}
  end

  def call_bound(_operation, _arguments),
    do: {:error, Error.new(:unsupported_capability, "collaboration runtime is unavailable")}

  defp bound_owner(%{backend_context: %{session_binding: binding}} = operation),
    do: Session.validate(binding, operation)

  defp bound_owner(operation),
    do: {:ok, get_in(operation, [:backend_context, :resource_owner])}

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
  def call(%{collaboration_binding: _} = operation),
    do:
      ToolEffects.reject(
        operation,
        Error.new(:forbidden, "bound collaboration requires call_bound/2")
      )

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
         catalog_revisions: %{},
         parent_binding: nil,
         parent_pid: nil,
         parent_incarnation: 1,
         parent_monitor: nil,
         parent_recovery: false,
         mailboxes: %{},
         input_activity: %{},
         deliveries: %{},
         interaction_deliveries: %{},
         settlements: %{},
         settlement_queue: [],
         session_owner: nil,
         child_sessions: %{},
         session_closed: false,
         child_options: child_options,
         admission_receipt: admission_receipt,
         admissions: %{},
         bound_contracts: %{},
         triggering_invocation: nil,
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
  def handle_call({:resolve_interaction, correlation, value}, from, state) do
    with :ok <- validate_interaction_correlation(correlation),
         {:ok, _public_value} <- Conversation.public_interaction(value),
         {:ok, agent} <- interaction_destination(state, correlation) do
      {:noreply, deliver_interaction(state, agent, correlation, value, from)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel_interaction, correlation, reason}, from, state) do
    with :ok <- validate_interaction_correlation(correlation),
         :ok <- validate_cancellation_reason(reason),
         {:ok, agent} <- interaction_destination(state, correlation),
         false <- settling?(state, agent.name) do
      state =
        put_in(
          state,
          [:agents, agent.name, :interaction_resolution_id],
          correlation.interaction_id
        )

      defer_settlement(state, [agent.name], {:cancel_interaction, correlation, reason}, from)
    else
      true -> {:reply, {:error, settlement_conflict()}, state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:notify_active, operation, recipient, notification}, from, state) do
    with {:ok, sender} <- authenticate(operation, state),
         true <-
           operation[:incarnation] == sender.incarnation or
             validation("notification sender incarnation differs"),
         :ok <- notification_sender_owner(state, sender, operation),
         :ok <- notification_payload(notification),
         true <- is_map(recipient) or validation("notification recipient must be an identity") do
      case notification_destination(state, recipient) do
        {:skip, status} ->
          {:reply, {:ok, %{status: status}}, state}

        {:ok, name, destination} ->
          envelope =
            communication(sender, :notification, notification.id)
            |> Map.put(:metadata, Map.get(notification, :metadata, %{}))

          queue_message(state, name, destination, notification.text, envelope, from, nil)
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

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

  def handle_call({:rebind_parent, binding, authority, catalog_revision}, _from, state) do
    owner = {binding.owner_id, binding.incarnation}

    cond do
      not is_integer(catalog_revision) or catalog_revision < 1 ->
        {:reply, validation("invalid parent catalog revision"), state}

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
             catalog_revisions:
               Map.put(
                 state.catalog_revisions,
                 {binding.run_id, Map.get(binding, :run_incarnation, 1)},
                 catalog_revision
               ),
             parent_binding: binding,
             session_owner: owner
         }}
    end
  end

  def handle_call({:authorize_managed_tool, expected, descriptor, invocation}, from, state) do
    name = state.run_index[invocation.run_id]
    agent = state.agents[name]

    result =
      with true <-
             (not state.session_closed and expected.manager_id == state.manager_id and
                agent != nil and agent.id == expected.agent_id and agent.run_id == expected.run_id and
                agent.incarnation == expected.incarnation and
                invocation.incarnation == agent.incarnation and
                agent.pid == elem(from, 0) and agent.status == :running and agent.closure == :open and
                not settling?(state, name)) or
               {:error, Error.new(:forbidden, "stale managed tool admission")},
           {:ok, _} <-
             Policy.authorize_tool(current_child_authority(state, agent), descriptor, invocation),
           :ok <- bound_parent_authority(state, descriptor, invocation),
           do: :ok

    {:reply, result, state}
  end

  def handle_call({:adopt_catalog, binding, expected, catalog}, from, state) do
    key = {binding.run_id, binding.run_incarnation}
    current = Map.get(state.catalog_revisions, key)

    cond do
      elem(from, 0) != binding.session or state.session_closed or current != expected or
        catalog.revision != expected + 1 or catalog.authority.run_id != binding.run_id ->
        {:reply, {:error, Error.new(:forbidden, "stale catalog adoption")}, state}

      state.parent_binding == binding ->
        if catalog.authority.caller == state.parent_authority.caller do
          next = %{
            state
            | parent_authority: catalog.authority,
              session_authority: catalog.authority,
              catalog_revisions: Map.put(state.catalog_revisions, key, catalog.revision)
          }

          {:reply, :ok, next}
        else
          {:reply, {:error, Error.new(:forbidden, "catalog caller differs")}, state}
        end

      true ->
        case Enum.find(state.child_sessions, fn {_id, entry} ->
               entry.binding == binding and entry.status == :accepted
             end) do
          {id, entry} ->
            name = state.run_index[binding.run_id]
            agent = state.agents[name]

            allowed =
              if agent,
                do: publication_within_ancestors?(state, agent, catalog.authority),
                else: false

            if (agent && agent.incarnation == binding.run_incarnation) and allowed do
              opts =
                agent.opts
                |> Keyword.put(:authority, catalog.authority)
                |> Keyword.put(:registry, catalog.registry)
                |> Keyword.put(:tools, catalog.tools)

              next = %{
                state
                | agents:
                    Map.put(state.agents, name, %{
                      agent
                      | authority: catalog.authority,
                        opts: opts
                    }),
                  child_sessions:
                    Map.put(state.child_sessions, id, %{entry | authority: catalog.authority}),
                  catalog_revisions: Map.put(state.catalog_revisions, key, catalog.revision)
              }

              {:reply, :ok, next}
            else
              {:reply,
               {:error,
                Error.new(:forbidden, "child catalog exceeds committed ancestor authority")},
               state}
            end

          nil ->
            {:reply, {:error, Error.new(:forbidden, "catalog binding is not in this tree")},
             state}
        end
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
      map_size(state.settlements) == 0 and state.settlement_queue == [] and
        Enum.all?(state.agents, fn {_name, agent} ->
          case transfer_snapshot(agent) do
            {:ok, snapshot} ->
              if snapshot.run.state == :unknown_outcome do
                safe_replacement(snapshot) == :ok
              else
                not match?({:uncertain, _}, snapshot.resource_cleanup)
              end

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

  def handle_call(:close_session, from, state) do
    defer_settlement(state, Map.keys(state.agents), :close_session, from)
  end

  def handle_call({:close_session, owner}, from, state) do
    if state.session_owner == owner,
      do: defer_settlement(state, Map.keys(state.agents), :close_session, from),
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

  def handle_call({:bind_contract, action, contract}, _from, state) do
    contract =
      Map.update!(
        contract,
        :backend_context,
        &Map.merge(&1, %{runtime: self(), family: :collaboration})
      )

    binding = CollaborationBinding.new(state.manager_id, action, Contract.descriptor(contract))
    contract = Map.put(contract, :collaboration_binding, binding)
    descriptor = Contract.descriptor(contract)

    {:reply, {:ok, contract},
     %{
       state
       | bound_contracts: Map.put_new(state.bound_contracts, binding.fingerprint, descriptor)
     }}
  end

  def handle_call({:bound_tool, operation, arguments, owner}, from, state) do
    with {:ok, descriptor} <- bound_descriptor(operation, state),
         {:ok, caller} <- authenticate_bound(operation, owner, descriptor, state),
         {:ok, _original} <- bound_original_arguments(descriptor, operation),
         {:ok, arguments} <-
           InputSchema.validate(
             bound_schema(descriptor.collaboration_binding.action, state),
             arguments
           ) do
      next =
        state
        |> update_parent(caller)
        |> Map.put(:triggering_invocation, invocation_summary(operation))

      action = bound_action(descriptor.collaboration_binding.action)

      case dispatch_request(action, arguments, from, caller, next) do
        {:reply, {:refused, error}, next} ->
          rejection_reply(operation, error, %{next | triggering_invocation: nil})

        {:reply, result, next} ->
          {:reply, result, %{next | triggering_invocation: nil}}

        {:noreply, next} ->
          {:noreply, %{next | triggering_invocation: nil}}
      end
    else
      {:error, %Error{} = error} -> rejection_reply(operation, error, state)
    end
  end

  def handle_call({:tool, profile, operation}, from, state) do
    with {:ok, caller} <- authenticate_native(profile, operation, state),
         {:ok, action} <- action(profile, operation.tool_name) do
      state = update_parent(state, caller)

      case dispatch_request(action, operation.arguments, from, caller, state) do
        {:reply, {:refused, error}, next} -> rejection_reply(operation, error, next)
        result -> result
      end
    else
      {:error, %Error{} = error} -> rejection_reply(operation, error, state)
    end
  end

  defp update_parent(state, caller) do
    if caller.name == state.parent_name,
      do: %{
        state
        | parent_authority: caller.authority,
          root_goal_context: Map.take(caller, [:goal, :goal_binding])
      },
      else: state
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

  # Settlement waits run outside the manager. Only identity-checked evidence is
  # installed; existing reducers still own lifecycle state, revisions and replies.
  defp dispatch_request(action, arguments, from, caller, state) do
    case settlement_targets(state, action, arguments, caller) do
      {:ok, names} ->
        defer_settlement(state, names, {:dispatch, action, arguments, caller}, from)

      :none ->
        target = arguments["target"] || arguments["id"]

        if busy_target?(state, target),
          do: {:reply, {:refused, settlement_conflict()}, state},
          else: dispatch(action, arguments, from, caller, state)
    end
  end

  defp settlement_targets(state, action, arguments, caller)
       when action in [:interrupt, :close, :send_input] do
    with true <- settlement_input?(action, arguments),
         {:ok, name, agent} <- resolve_target(state, arguments["target"]),
         true <- action != :interrupt or agent.execution_reserved,
         :ok <- settlement_caller(state, action, caller, arguments["target"], name) do
      {:ok, if(action == :close, do: [name | descendant_names(state, name)], else: [name])}
    else
      _ -> :none
    end
  end

  defp settlement_targets(_state, _action, _arguments, _caller), do: :none

  defp settlement_input?(:send_input, arguments) do
    message = arguments["message"] || input_items_text(arguments["items"])
    arguments["interrupt"] == true and is_binary(message) and String.trim(message) != ""
  end

  defp settlement_input?(_, _), do: true

  defp settlement_caller(state, :interrupt, caller, target, name) do
    with :ok <- reject_interrupt_target(state, caller, target),
         do: reject_interrupt_target(state, caller, name)
  end

  defp settlement_caller(_, _, _, _, _), do: :ok

  defp busy_target?(state, target) do
    case resolve_target(state, target) do
      {:ok, name, _} -> settling?(state, name)
      _ -> false
    end
  end

  defp settling?(state, name) do
    Enum.any?(state.settlements, fn {_, entry} -> Map.has_key?(entry.pins, name) end) or
      Enum.any?(state.settlement_queue, &Map.has_key?(&1.pins, name))
  end

  defp settlement_conflict,
    do: Error.new(:resource_conflict, "agent lifecycle settlement is pending")

  defp settlement_pin(state, agent),
    do:
      Map.merge(Map.take(agent, [:id, :attempt_id, :run_id, :incarnation, :pid]), %{
        manager_id: state.manager_id,
        session_binding: get_in(state.child_sessions, [agent.id, :binding])
      })

  defp defer_settlement(state, names, command, from) do
    pins = Map.new(names, &{&1, settlement_pin(state, state.agents[&1])})
    previous = Map.new(names, &{&1, public_status(state.agents[&1])})
    request = %{pins: pins, names: names, command: command, from: from, previous: previous}
    overlap = Enum.any?(names, &settling?(state, &1))
    state = fence_settlement(state, request)

    if overlap,
      do: {:noreply, %{state | settlement_queue: state.settlement_queue ++ [request]}},
      else: {:noreply, start_settlement(state, request)}
  end

  # The child may already have advanced beyond the manager's observed pending
  # interaction. Only its exact acceptance may invalidate that projection.
  defp fence_settlement(state, %{command: {:cancel_interaction, _, _}}), do: state

  defp fence_settlement(state, request) do
    closing =
      request.command == :close_session or match?({:dispatch, :close, _, _}, request.command)

    state =
      if request.command == :close_session,
        do: %{state | session_closed: true, parent_run_id: nil, parent_binding: nil},
        else: state

    Enum.reduce(request.names, state, fn name, acc ->
      acc = invalidate_interaction(acc, name, settlement_conflict())
      agent = acc.agents[name]
      closure = if closing and agent.closure != :confirmed, do: :in_progress, else: agent.closure
      reserved = agent.execution_reserved or agent.closure != :confirmed
      put_in(acc, [:agents, name], %{agent | execution_reserved: reserved, closure: closure})
    end)
  end

  defp start_settlement(state, request) do
    token = make_ref()
    manager = self()

    agents =
      Enum.map(request.names, fn name ->
        agent =
          Map.put(
            state.agents[name],
            :managed_session,
            state.child_sessions[state.agents[name].id]
          )

        {name, agent}
      end)

    all = request.command == :close_session

    spec = %{
      id: token,
      start:
        {Task, :start_link,
         [
           fn ->
             send(manager, {:settlement, token, collect_settlement(agents, all, request.command)})
           end
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(state.child_supervisor, spec) do
      {:ok, worker} ->
        timer =
          Process.send_after(
            self(),
            {:settlement_timeout, token},
            # Fence, cancellation, snapshot and close each have a bounded wait.
            # One final interval covers completion delivery and scheduling.
            @settlement_wait_ms * (@settlement_stages_per_target * max(1, length(agents)) + 1)
          )

        entry =
          Map.merge(request, %{worker: worker, monitor: Process.monitor(worker), timer: timer})

        put_in(state, [:settlements, token], entry)

      {:error, _} ->
        entry = Map.merge(request, %{worker: nil, monitor: nil, timer: nil})
        state = put_in(state, [:settlements, token], entry)
        send(self(), {:settlement, token, %{}})
        state
    end
  end

  defp collect_settlement([{name, agent}], _all, {:cancel_interaction, correlation, _reason}) do
    cancel = cancel_exact_interaction(agent.pid, correlation)
    snapshot = if cancel == :ok, do: settled_snapshot(agent), else: cancel
    evidence = %{cancel_result: cancel, settlement_result: snapshot}

    evidence =
      if cancel == :ok,
        do:
          Map.put(evidence, :session_close_result, close_child_session(agent[:managed_session])),
        else: evidence

    %{name => evidence}
  end

  defp collect_settlement(agents, _all, _command) do
    # Fence every Session before any cancellation or cleanup receipt can block.
    # Run cancellation also starts for every target before waiting on snapshots.
    fences =
      Map.new(agents, fn {name, agent} -> {name, fence_child_session(agent[:managed_session])} end)

    cancellations = Map.new(agents, fn {name, agent} -> {name, cancel_agent(agent)} end)

    Map.new(agents, fn {name, agent} ->
      cancel = cancellations[name]

      snapshot =
        with :ok <- fences[name],
             :ok <- normalize_cancel(cancel),
             do: settled_snapshot(agent)

      close = close_child_session(agent[:managed_session])
      {name, %{cancel_result: cancel, settlement_result: snapshot, session_close_result: close}}
    end)
  end

  defp fence_child_session(nil), do: :ok
  defp fence_child_session(%{status: status}) when status in [:rejected, :closed], do: :ok

  defp fence_child_session(entry) do
    Session.fence_managed_child(Map.take(entry, [:admission, :binding]))
  catch
    :exit, reason ->
      {:error,
       Error.new(:unknown_outcome, "child Session admission fence acknowledgement unavailable",
         cause: reason
       )}
  end

  defp close_child_session(nil), do: :not_managed
  defp close_child_session(%{status: :rejected}), do: :not_managed
  defp close_child_session(%{status: :closed, close_result: result}), do: result

  defp close_child_session(%{binding: binding}) do
    task =
      Task.async(fn ->
        try do
          Session.close(binding.session)
        catch
          :exit, reason ->
            {:error,
             Error.new(:unknown_outcome, "child Session close acknowledgement unavailable",
               cause: reason
             )}
        end
      end)

    case Task.yield(task, @settlement_wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{status: :confirmed, owner_id: id}} = result} when id == binding.owner_id ->
        result

      {:ok, {:error, %Error{}} = error} ->
        error

      _ ->
        {:error,
         Error.new(
           :unknown_outcome,
           "child Session close acknowledgement timed out or mismatched"
         )}
    end
  end

  defp confirmed_session_close?({:ok, %{status: :confirmed}}), do: true
  defp confirmed_session_close?(:not_managed), do: true
  defp confirmed_session_close?(_), do: false

  defp child_session_notification(
         state,
         %{admission: %{agent_id: _}, binding: _} = child,
         notification
       ) do
    case state.child_sessions[child.admission.agent_id] do
      %{binding: binding, admission: admission} = entry
      when binding == child.binding and admission == child.admission ->
        case notification do
          :closing ->
            state

          {:closed, result} ->
            confirmed =
              match?(
                {:ok, %{status: :confirmed, owner_id: id}} when id == binding.owner_id,
                result
              )

            status = if confirmed, do: :closed, else: :uncertain

            state =
              put_in(state, [:child_sessions, admission.agent_id], %{
                entry
                | status: status,
                  close_result: result
              })

            case Enum.find(state.agents, fn {_name, agent} -> agent.id == admission.agent_id end) do
              {name, _} when not confirmed ->
                reserve_uncertain(
                  state,
                  name,
                  Error.new(:unknown_outcome, "managed child Session close is unconfirmed")
                )

              _ ->
                state
            end
        end

      _ ->
        state
    end
  end

  defp child_session_notification(state, _, _), do: state

  defp cancel_exact_interaction(pid, correlation) do
    Conversation.cancel_interaction(pid, correlation)
  catch
    :exit, _ ->
      {:error, Error.new(:unknown_outcome, "interaction cancellation acknowledgement was lost")}
  end

  defp complete_settlement(state, token, evidence) do
    case Map.pop(state.settlements, token) do
      {nil, _} ->
        state

      {entry, settlements} ->
        stop_settlement(entry)
        state = %{state | settlements: settlements}

        if Enum.all?(entry.pins, fn {name, pin} ->
             # A child DOWN changes its PID, but the same activation still needs
             # the failure reducer. Per-child evidence retains the full PID check.
             Map.delete(settlement_pin(state, state.agents[name]), :pid) == Map.delete(pin, :pid)
           end) do
          finish_settlement(state, entry, evidence)
        else
          GenServer.reply(
            entry.from,
            {:error, Error.new(:unknown_outcome, "agent settlement identity changed")}
          )

          drain_settlement_queue(state)
        end
    end
  end

  defp finish_settlement(state, entry, evidence) do
    state = install_settlement(state, entry, evidence)
    {result, state} = continue_settlement(state, entry)
    GenServer.reply(entry.from, settlement_reply(result, entry))
    state = finish_settlement_events(state, entry.names)

    state =
      Enum.reduce(entry.names, state, fn name, acc ->
        update_in(acc, [:agents, name], &Map.delete(&1, :settlement_evidence))
      end)

    drain_settlement_queue(wake_waiters(state))
  end

  defp settlement_reply({:ok, %{previous_status: _} = result}, entry),
    do: {:ok, %{result | previous_status: entry.previous[hd(entry.names)]}}

  defp settlement_reply(result, _entry), do: result

  defp stop_settlement(entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])

    if is_pid(entry.worker) and Process.alive?(entry.worker),
      do: Process.exit(entry.worker, :kill)
  end

  defp install_settlement(state, entry, evidence) do
    Enum.reduce(entry.pins, state, fn {name, pin}, acc ->
      agent = acc.agents[name]
      supplied = evidence[name]
      error = Error.new(:unknown_outcome, "agent settlement was not acknowledged")
      unavailable = %{cancel_result: {:error, error}, settlement_result: {:error, error}}

      accepted =
        if settlement_pin(acc, agent) == pin and valid_settlement?(supplied, pin),
          do: supplied,
          else: unavailable

      acc =
        case {acc.child_sessions[agent.id], accepted[:session_close_result]} do
          {nil, _} ->
            acc

          {_child, nil} ->
            acc

          {_child, :not_managed} ->
            acc

          {child, result} ->
            status = if confirmed_session_close?(result), do: :closed, else: :uncertain

            put_in(acc, [:child_sessions, agent.id], %{
              child
              | status: status,
                close_result: result
            })
        end

      put_in(acc, [:agents, name], Map.put(agent, :settlement_evidence, accepted))
    end)
  end

  defp valid_settlement?(%{settlement_result: {:ok, %{run: run}}}, pin),
    do: run.run_id == pin.run_id and run.incarnation == pin.incarnation

  defp valid_settlement?(%{settlement_result: {:error, %Error{}}}, _pin), do: true
  defp valid_settlement?(_, _), do: false

  defp continue_settlement(state, %{command: :close_session}) do
    {:reply, result, next} = close_session_state(state)
    {result, next}
  end

  defp continue_settlement(state, %{command: {:cancel_interaction, correlation, reason}} = entry) do
    [name] = entry.names
    agent = state.agents[name]

    case agent.settlement_evidence.cancel_result do
      :ok ->
        metadata = %{interaction_id: correlation.interaction_id, reason: reason}

        case interrupt_target(state, name, agent, metadata) do
          {:ok, next} -> {:ok, next}
          {:error, error, next} -> {{:error, error}, next}
        end

      {:error, %Error{class: :resource_conflict} = error} ->
        {{:error, error}, state}

      {:error, %Error{} = error} ->
        {{:error, error}, reserve_uncertain(state, name, error)}
    end
  end

  defp continue_settlement(state, %{command: {:dispatch, action, arguments, caller}, from: from}) do
    case dispatch(action, arguments, from, caller, state) do
      {:reply, result, next} -> {result, next}
    end
  end

  defp finish_settlement_events(state, names) do
    Enum.reduce(names, state, fn name, acc ->
      {event, agent} = Map.pop(acc.agents[name], :settlement_event)
      acc = put_in(acc, [:agents, name], agent)
      if event, do: update_from_event(acc, event.run_id, event.event), else: acc
    end)
  end

  defp drain_settlement_queue(state) do
    {ready, waiting} =
      Enum.split_with(state.settlement_queue, fn request ->
        not Enum.any?(state.settlements, fn {_, active} ->
          Enum.any?(request.names, &Map.has_key?(active.pins, &1))
        end)
      end)

    Enum.reduce(ready, %{state | settlement_queue: waiting}, fn request, acc ->
      cond do
        Enum.any?(request.names, &settling?(acc, &1)) ->
          %{acc | settlement_queue: acc.settlement_queue ++ [request]}

        Enum.all?(request.pins, fn {name, pin} ->
          agent = acc.agents[name]

          agent.id == pin.id and agent.run_id == pin.run_id and
            agent.incarnation == pin.incarnation and
              (agent.pid == pin.pid or agent.closure == :confirmed)
        end) ->
          pins = Map.new(request.names, &{&1, settlement_pin(acc, acc.agents[&1])})
          start_settlement(acc, %{request | pins: pins})

        true ->
          GenServer.reply(request.from, {:error, settlement_conflict()})
          acc
      end
    end)
  end

  @impl true
  def handle_info({:cleanup_failed_birth, name, attempt_id}, state) do
    agent = state.agents[name]
    entry = state.child_sessions[agent.id]

    if agent.attempt_id == attempt_id and entry != nil do
      manager = self()
      # Cleanup runs independently of manager admission and observation calls.
      worker = fn ->
        cancel = cancel_agent(agent)
        close = close_child_session(entry)

        send(
          manager,
          {:failed_birth_closed, Map.take(entry, [:admission, :binding]), cancel, close}
        )
      end

      DynamicSupervisor.start_child(state.child_supervisor, %{
        id: make_ref(),
        start: {Task, :start_link, [worker]},
        restart: :temporary
      })
    end

    {:noreply, state}
  end

  def handle_info({:failed_birth_closed, identity, _cancel, result}, state) do
    {:noreply, child_session_notification(state, identity, {:closed, result})}
  end

  def handle_info({:managed_child_session_closing, child}, state) do
    {:noreply, child_session_notification(state, child, :closing)}
  end

  def handle_info({:managed_child_session_closed, child, result}, state) do
    {:noreply, child_session_notification(state, child, {:closed, result})}
  end

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
        entries = retained_mailbox(Map.get(state.mailboxes, name, []) ++ mailbox)

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

  def handle_info({:interaction_delivery, token, result}, state),
    do: {:noreply, complete_interaction_delivery(state, token, result)}

  def handle_info({:settlement, token, evidence}, state),
    do: {:noreply, complete_settlement(state, token, evidence)}

  def handle_info({:settlement_timeout, token}, state),
    do: {:noreply, complete_settlement(state, token, %{})}

  def handle_info({:interaction_delivery_timeout, token}, state) do
    {:noreply,
     complete_interaction_delivery(
       state,
       token,
       {:error, Error.new(:unknown_outcome, "interaction resolution was not acknowledged")}
     )}
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

  def handle_info({:managed_child_runtime, identity, run_id, event}, state) when is_map(event) do
    valid =
      case state.run_index[run_id] do
        nil ->
          false

        name ->
          agent = state.agents[name]

          case state.child_sessions[agent.id] do
            %{binding: binding, admission: admission} ->
              identity == %{binding: binding, admission: admission} and
                admission.run_id == agent.run_id and admission.attempt_id == agent.attempt_id and
                admission.incarnation == agent.incarnation and
                event[:incarnation] == agent.incarnation

            _ ->
              false
          end
      end

    state = if valid, do: update_from_event(state, run_id, event), else: state
    {:noreply, wake_waiters(state)}
  end

  def handle_info({:agent_runtime, run_id, event}, state) when is_map(event) do
    managed =
      case state.run_index[run_id] do
        nil -> false
        name -> Map.has_key?(state.child_sessions, state.agents[name].id)
      end

    state = if managed, do: state, else: update_from_event(state, run_id, event)
    {:noreply, wake_waiters(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.child_sessions, fn {_id, entry} ->
           entry.monitor == ref and entry.binding.session == pid
         end) do
      {_id, %{status: :closed}} ->
        {:noreply, state}

      {id, entry} ->
        error =
          Error.new(:unknown_outcome, "managed child Session infrastructure stopped",
            cause: reason
          )

        state = put_in(state, [:child_sessions, id], %{entry | status: :uncertain})

        case Enum.find(state.agents, fn {_name, agent} -> agent.id == id end) do
          {name, agent} ->
            if is_pid(agent.pid), do: send(agent.pid, {:codex_session_close, entry.binding.token})
            {:noreply, reserve_uncertain(state, name, error)}

          nil ->
            {:noreply, state}
        end

      nil ->
        settlement_or_child_down(state, ref, pid, reason)
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

  defp settlement_or_child_down(state, ref, pid, reason) do
    case Enum.find(state.settlements, fn {_, entry} -> entry.monitor == ref end) do
      {token, _} -> {:noreply, complete_settlement(state, token, %{})}
      nil -> interaction_or_child_down(state, ref, pid, reason)
    end
  end

  defp interaction_or_child_down(state, ref, pid, reason) do
    case Enum.find(state.interaction_deliveries, fn {_token, entry} ->
           entry.monitor == ref and entry.worker == pid
         end) do
      {token, _entry} ->
        {:noreply,
         complete_interaction_delivery(
           state,
           token,
           {:error, Error.new(:unknown_outcome, "interaction delivery acknowledgement was lost")}
         )}

      nil ->
        child_or_observer_down(state, ref, reason)
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.settlements, fn {_, entry} ->
      stop_settlement(entry)

      GenServer.reply(
        entry.from,
        {:error, Error.new(:unknown_outcome, "collaboration manager stopped")}
      )
    end)

    Enum.each(state.settlement_queue, fn entry ->
      GenServer.reply(
        entry.from,
        {:error, Error.new(:unknown_outcome, "collaboration manager stopped")}
      )
    end)

    Enum.each(state.interaction_deliveries, fn {_token, entry} ->
      stop_interaction_delivery(entry)

      reply_interaction_delivery(
        entry,
        Error.new(:unknown_outcome, "collaboration manager stopped")
      )
    end)

    Enum.each(state.deliveries, fn {_token, entry} ->
      Process.cancel_timer(entry.timer)
      Process.exit(entry.worker, :kill)
    end)

    Enum.each(state.waiters, fn {_token, waiter} ->
      if waiter.timer, do: Process.cancel_timer(waiter.timer)
    end)

    # A :shutdown exit from this linked supervisor would replace the manager's
    # own exit reason while terminate/2 is still running.
    if Process.alive?(state.child_supervisor),
      do: Supervisor.stop(state.child_supervisor, :normal)

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
            pending_interaction: nil,
            interaction_closed: false,
            interaction_resolution_id: nil,
            interaction_ids: MapSet.new(),
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

  defp validate_interaction_correlation(correlation) when is_map(correlation) do
    keys = [:manager_id, :agent_id, :run_id, :incarnation, :interaction_id]

    if Enum.sort(Map.keys(correlation)) == Enum.sort(keys) and
         Enum.all?([:manager_id, :agent_id, :run_id, :interaction_id], fn key ->
           valid_interaction_text?(correlation[key])
         end) and is_integer(correlation.incarnation) and correlation.incarnation > 0 do
      :ok
    else
      validation("invalid interaction correlation")
    end
  end

  defp validate_interaction_correlation(_), do: validation("invalid interaction correlation")

  defp valid_interaction_text?(value),
    do: is_binary(value) and value != "" and String.valid?(value)

  defp validate_cancellation_reason(reason) do
    if valid_interaction_text?(reason) and byte_size(reason) <= 1024 and
         String.trim(reason) != "",
       do: :ok,
       else: validation("cancellation reason must be nonblank UTF-8 text of at most 1024 bytes")
  end

  defp interaction_correlation(state, agent, interaction_id) do
    %{
      manager_id: state.manager_id,
      agent_id: agent.id,
      run_id: agent.run_id,
      incarnation: agent.incarnation,
      interaction_id: interaction_id
    }
  end

  defp interaction_destination(state, correlation) do
    case Enum.find(state.agents, fn {_name, agent} -> agent.id == correlation.agent_id end) do
      nil ->
        {:error, Error.new(:not_found, "interaction child was not found")}

      {_name, agent} ->
        if accepting_interactions?(state, agent) and
             interaction_correlation(state, agent, correlation.interaction_id) == correlation and
             match?(%{id: id} when id == correlation.interaction_id, agent.pending_interaction) and
             agent.interaction_resolution_id != correlation.interaction_id do
          {:ok, agent}
        else
          {:error, Error.new(:resource_conflict, "interaction is stale or unavailable")}
        end
    end
  end

  defp accepting_interactions?(state, agent) do
    not state.session_closed and not agent.interaction_closed and
      agent.status == :running and agent.closure == :open and is_pid(agent.pid)
  end

  defp pinned_interaction_child?(state, %{pid: pid} = agent, entry) do
    pid == entry.pid and
      interaction_correlation(state, agent, entry.correlation.interaction_id) == entry.correlation
  end

  defp pinned_interaction_child?(_state, _agent, _entry), do: false

  defp deliver_interaction(state, agent, correlation, value, from) do
    owner = self()
    token = make_ref()

    # Temporary children share the manager's supervisor lifetime, including when
    # the manager is killed before terminate/2 can clean up delivery waiters.
    task = fn ->
      result =
        try do
          Conversation.resolve(agent.pid, correlation.interaction_id, value)
        rescue
          _ -> {:error, Error.new(:unknown_outcome, "interaction delivery failed")}
        catch
          :exit, _ ->
            {:error, Error.new(:unknown_outcome, "interaction child acknowledgement was lost")}
        end

      send(owner, {:interaction_delivery, token, result})
    end

    case DynamicSupervisor.start_child(state.child_supervisor, {Task, task}) do
      {:ok, worker} ->
        entry = %{
          worker: worker,
          monitor: Process.monitor(worker),
          timer:
            Process.send_after(
              self(),
              {:interaction_delivery_timeout, token},
              @settlement_wait_ms
            ),
          from: from,
          name: agent.name,
          pid: agent.pid,
          correlation: correlation,
          checkpoint_acknowledged: false
        }

        state
        |> put_in([:agents, agent.name, :interaction_resolution_id], correlation.interaction_id)
        |> put_in([:interaction_deliveries, token], entry)

      {:error, _reason} ->
        GenServer.reply(
          from,
          {:error, Error.new(:unknown_outcome, "interaction delivery could not start")}
        )

        put_in(
          state,
          [:agents, agent.name, :interaction_resolution_id],
          correlation.interaction_id
        )
    end
  end

  defp complete_interaction_delivery(state, token, result) do
    case Map.pop(state.interaction_deliveries, token) do
      {nil, _} ->
        state

      {entry, deliveries} ->
        stop_interaction_delivery(entry)
        result = interaction_delivery_result(state, entry, result)

        # Keep the submitted interaction reserved even after an uncertain outcome.
        # A later event can reconcile it, but no automatic or duplicate retry is safe.
        GenServer.reply(entry.from, result)
        %{state | interaction_deliveries: deliveries}
    end
  end

  defp interaction_delivery_result(state, entry, result) do
    agent = state.agents[entry.name]

    cond do
      not pinned_interaction_child?(state, agent, entry) ->
        {:error, Error.new(:resource_conflict, "interaction child identity changed")}

      entry.checkpoint_acknowledged ->
        :ok

      not accepting_interactions?(state, agent) ->
        {:error, Error.new(:resource_conflict, "interaction child is unavailable")}

      true ->
        normalize_interaction_acknowledgement(result)
    end
  end

  defp normalize_interaction_acknowledgement(:ok), do: :ok
  defp normalize_interaction_acknowledgement({:error, %Error{} = error}), do: {:error, error}

  defp normalize_interaction_acknowledgement(_),
    do: {:error, Error.new(:unknown_outcome, "invalid interaction acknowledgement")}

  defp acknowledge_interaction_checkpoint(state, name, id) do
    agent = state.agents[name]

    deliveries =
      Map.new(state.interaction_deliveries, fn {token, entry} ->
        if entry.name == name and entry.correlation.interaction_id == id and
             pinned_interaction_child?(state, agent, entry),
           do: {token, %{entry | checkpoint_acknowledged: true}},
           else: {token, entry}
      end)

    %{state | interaction_deliveries: deliveries}
  end

  defp reply_interaction_delivery(%{checkpoint_acknowledged: true} = entry, _error),
    do: GenServer.reply(entry.from, :ok)

  defp reply_interaction_delivery(entry, error), do: GenServer.reply(entry.from, {:error, error})

  defp stop_interaction_delivery(entry) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.monitor, [:flush])
    if Process.alive?(entry.worker), do: Process.exit(entry.worker, :kill)
    :ok
  end

  defp invalidate_interaction(state, name, error) do
    deliveries =
      Enum.reduce(state.interaction_deliveries, state.interaction_deliveries, fn {token, entry},
                                                                                 acc ->
        if entry.name == name do
          stop_interaction_delivery(entry)
          reply_interaction_delivery(entry, error)
          Map.delete(acc, token)
        else
          acc
        end
      end)

    state
    |> Map.put(:interaction_deliveries, deliveries)
    |> put_in([:agents, name, :pending_interaction], nil)
    |> put_in([:agents, name, :interaction_closed], true)
    |> put_in([:agents, name, :interaction_resolution_id], nil)
  end

  defp child_or_observer_down(state, ref, reason) do
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

          state =
            state
            |> invalidate_interaction(
              name,
              Error.new(:unknown_outcome, "agent exited before resolution acknowledgement")
            )
            |> put_in([:agents, name], %{
              next_agent
              | pending_interaction: nil,
                interaction_resolution_id: nil,
                interaction_closed: true
            })

          state = %{state | updates: MapSet.put(state.updates, name)}
          state = publish(state, :process_exited, name)
          {:noreply, wake_waiters(state)}
        else
          {:noreply, state}
        end
    end
  end

  defp update_from_event(state, run_id, %{type: type} = event)
       when type in [:interaction_requested, :interaction_resolved, :storage_failed] do
    case Map.fetch(state.run_index, run_id) do
      {:ok, name} ->
        agent = state.agents[name]

        if agent.run_id == run_id and agent.incarnation == event[:incarnation] and
             agent.status == :running and agent.closure == :open and
             not agent.interaction_closed and not state.session_closed do
          update_interaction_event(state, name, event)
        else
          state
        end

      :error ->
        state
    end
  end

  defp update_from_event(state, run_id, %{type: type} = event)
       when type in [:run_completed, :run_failed, :run_cancelled] do
    case Map.fetch(state.run_index, run_id) do
      :error ->
        state

      {:ok, name} ->
        agent = Map.fetch!(state.agents, name)

        cond do
          agent.run_id != run_id or agent.status != :running or
              event[:incarnation] != agent.incarnation ->
            state

          settling?(state, name) ->
            put_in(
              state,
              [:agents, name],
              Map.put(agent, :settlement_event, %{run_id: run_id, event: event})
            )

          true ->
            status =
              case {type, agent.status} do
                {:run_completed, _status} -> :completed
                {:run_cancelled, _status} -> :interrupted
                {_type, _status} -> {:errored, event_error(event)}
              end

            final = terminal_message(settlement_snapshot(agent) || agent.pid, event)

            state =
              state
              |> invalidate_interaction(
                name,
                Error.new(:resource_conflict, "agent run has settled")
              )
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

  defp update_interaction_event(state, name, %{type: :interaction_requested} = event) do
    agent = state.agents[name]
    interaction_id = event[:interaction_id]

    with true <- valid_interaction_text?(interaction_id),
         false <- MapSet.member?(agent.interaction_ids, interaction_id),
         {:ok, request} <- Conversation.public_interaction(event[:request]) do
      pending = %{
        id: interaction_id,
        request: request,
        correlation: interaction_correlation(state, agent, interaction_id)
      }

      state
      |> put_in([:agents, name, :pending_interaction], pending)
      |> put_in([:agents, name, :interaction_resolution_id], nil)
      |> put_in(
        [:agents, name, :interaction_ids],
        MapSet.put(agent.interaction_ids, interaction_id)
      )
      |> publish(:interaction_requested, name, %{interaction_id: interaction_id})
    else
      _ -> state
    end
  end

  defp update_interaction_event(state, name, %{type: :interaction_resolved} = event) do
    interaction_id = event[:interaction_id]

    case state.agents[name].pending_interaction do
      %{id: id} when id == interaction_id ->
        state
        |> acknowledge_interaction_checkpoint(name, id)
        |> put_in([:agents, name, :pending_interaction], nil)
        |> publish(:interaction_resolved, name, %{interaction_id: id})

      _ ->
        state
    end
  end

  defp update_interaction_event(state, name, %{type: :storage_failed} = event) do
    error =
      case event[:error] do
        %Error{} = error -> error
        _ -> Error.new(:unknown_outcome, "agent storage failed")
      end

    state = state |> invalidate_interaction(name, error) |> publish(:storage_failed, name)

    if Map.has_key?(state.child_sessions, state.agents[name].id),
      do: reserve_uncertain(state, name, error),
      else: state
  end

  defp terminal_message(pid, event) do
    case if(is_map(pid), do: pid, else: Conversation.status(pid)) do
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

  defp deliver(state, name, agent, action, message) do
    cond do
      match?({:uncertain, _}, agent.closure) ->
        {:error, Error.new(:unknown_outcome, "agent ownership or execution is unconfirmed")}

      state.session_closed or settling?(state, name) or agent.closure == :in_progress ->
        {:error, settlement_conflict()}

      true ->
        deliver_now(state, name, agent, action, message)
    end
  end

  defp deliver_now(state, name, agent, :interrupt_message, message) do
    with :ok <- cancel_agent(agent),
         {:ok, state} <- replace_agent(state, name, agent, message) do
      {:ok, state}
    else
      # Cancellation already ran, so replacement refusal cannot prove non-dispatch.
      {:refused, error, next} -> {:error, error, next}
      error -> error
    end
  end

  defp deliver_now(state, _name, %{status: :running, pid: pid}, :followup, message),
    do: normalize_delivery(state, Conversation.follow_up(pid, message))

  defp deliver_now(state, _name, %{status: :running, pid: pid}, :followup_v2, message),
    do: normalize_delivery(state, Conversation.follow_up(pid, message))

  defp deliver_now(state, name, %{status: status} = agent, :followup, message)
       when status in [:completed, :interrupted],
       do: replace_agent(state, name, agent, message)

  defp deliver_now(
         state,
         name,
         %{status: {:errored, _}, profile: :v2} = agent,
         :followup,
         message
       ),
       do: replace_agent(state, name, agent, message)

  defp deliver_now(state, name, %{status: status} = agent, :followup_v2, message)
       when status in [:completed, :interrupted],
       do: replace_agent(state, name, agent, message, :v2)

  defp deliver_now(state, name, %{status: {:errored, _}} = agent, :followup_v2, message),
    do: replace_agent(state, name, agent, message, :v2)

  defp deliver_now(_state, _name, _agent, _action, _message),
    do: {:error, Error.new(:resource_conflict, "agent is not accepting input")}

  defp normalize_delivery(state, {:ok, _}), do: {:ok, state}
  defp normalize_delivery(_state, {:error, %Error{} = error}), do: {:error, error}

  defp retained_mailbox(entries),
    do: Enum.reject(entries, &match?(%{collaboration: %{kind: :notification}}, &1))

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
          |> Keyword.put(:host_feedback, Map.get(snapshot.conversation, :host_feedback, []))
          |> Keyword.put(:subscriber, self())
          |> Keyword.put(
            :mailbox,
            retained_mailbox(
              Map.get(snapshot.conversation, :mailbox, []) ++ Map.get(state.mailboxes, name, [])
            )
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
                pending_interaction: nil,
                interaction_closed: false,
                interaction_resolution_id: nil,
                interaction_ids: MapSet.new(),
                result_delivery: nil,
                snapshot: nil,
                snapshot_identity: nil,
                closure: :open,
                execution_reserved: true
            }

            state =
              invalidate_interaction(
                state,
                name,
                Error.new(:resource_conflict, "agent was replaced")
              )

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
    agent = state.agents[name]

    state = %{
      state
      | catalog_revisions:
          Map.put(
            state.catalog_revisions,
            {agent.run_id, agent.incarnation},
            Keyword.get(opts, :catalog_revision, 1)
          )
    }

    opts =
      if state.session_owner do
        Keyword.put(opts, :managed_authorization, %{
          runtime: self(),
          manager_id: state.manager_id,
          agent_id: agent.id,
          run_id: agent.run_id,
          incarnation: agent.incarnation
        })
      else
        Keyword.delete(opts, :managed_authorization)
      end

    attempt = state.admissions[state.agents[name].attempt_id]

    {adoption, state} = adopt_child_session(state, name, opts, attempt)
    entry = state.child_sessions[state.agents[name].id]

    opts =
      if entry && entry.status == :accepted,
        do: Keyword.put(opts, :managed_child_identity, Map.take(entry, [:admission, :binding])),
        else: Keyword.delete(opts, :managed_child_identity)

    result =
      case adoption do
        :ok -> admission_operation(fn -> start_child(state.child_supervisor, opts) end)
        {:error, _} = error -> error
      end

    case result do
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
            execution_reserved: adopted_obligation?(state, state.agents[name].id),
            closure:
              if(adopted_obligation?(state, state.agents[name].id),
                do: {:uncertain, error},
                else: :confirmed
              )
        }

        next = state |> put_in([:agents, name], agent) |> publish(:settled, name)

        next =
          if adopted_obligation?(state, agent.id),
            do: update_in(next, [:agents, name], &Map.put(&1, :admission_uncertain, true)),
            else: next

        if adopted_obligation?(state, agent.id),
          do: send(self(), {:cleanup_failed_birth, name, attempt.attempt_id})

        {error, next} = reject_admission(next, attempt, :failed, error)
        {:error, error, next}
    end
  end

  defp retained_child_session(state, id, opts) do
    case state.child_sessions[id] do
      nil ->
        :ok

      %{status: status} when status in [:closed, :rejected] ->
        :ok

      %{status: status} when status in [:pending, :uncertain] ->
        {:error, Error.new(:unknown_outcome, "prior child Session obligation is unconfirmed")}

      %{binding: previous} ->
        case Keyword.get(opts, :session_binding) do
          %{session: session, owner_id: owner, incarnation: incarnation}
          when session == previous.session and owner == previous.owner_id and
                 incarnation == previous.incarnation ->
            :ok

          _ ->
            {:error, Error.new(:resource_conflict, "prior child Session closure is unconfirmed")}
        end
    end
  end

  defp adopt_child_session(state, name, opts, attempt) do
    agent = state.agents[name]
    binding = Keyword.get(opts, :session_binding)
    previous = state.child_sessions[agent.id]

    cond do
      is_nil(binding) and is_nil(previous) ->
        {:ok, state}

      is_nil(binding) and previous.status == :closed ->
        {:ok, state}

      not is_map(binding) or not is_pid(binding[:session]) ->
        {{:error, Error.new(:forbidden, "managed child requires its retained Session")}, state}

      previous != nil and previous.status != :closed and
          {previous.binding.session, previous.binding.owner_id, previous.binding.incarnation} !=
            {binding.session, binding[:owner_id], binding[:incarnation]} ->
        {{:error, Error.new(:resource_conflict, "prior child Session closure is unconfirmed")},
         state}

      previous != nil and previous.status in [:pending, :uncertain] ->
        {{:error, Error.new(:unknown_outcome, "prior Session adoption is unconfirmed")}, state}

      true ->
        admission = %{
          manager: self(),
          manager_id: state.manager_id,
          agent_id: agent.id,
          attempt_id: attempt.attempt_id,
          run_id: attempt.run_id,
          incarnation: attempt.incarnation
        }

        monitor =
          if previous && previous.binding.session == binding.session,
            do: previous.monitor,
            else: Process.monitor(binding.session)

        entry = %{
          binding: binding,
          admission: admission,
          authority: Keyword.get(opts, :authority),
          status: :pending,
          monitor: monitor,
          close_result: nil
        }

        state = put_in(state, [:child_sessions, agent.id], entry)

        result =
          try do
            Session.adopt_managed_child(binding, admission, entry.authority)
          catch
            :exit, reason ->
              {:error,
               Error.new(:unknown_outcome, "child Session adoption acknowledgement unavailable",
                 cause: reason
               )}
          end

        status =
          case result do
            :ok -> :accepted
            {:error, %Error{class: :unknown_outcome}} -> :uncertain
            {:error, _} -> :rejected
          end

        if status == :rejected, do: Process.demonitor(monitor, [:flush])
        entry = %{entry | status: status}
        {result, put_in(state, [:child_sessions, agent.id], entry)}
    end
  end

  defp adopted_obligation?(state, id),
    do:
      state.child_sessions[id] != nil and
        state.child_sessions[id].status in [:accepted, :pending, :uncertain]

  defp fail_activation(state, name, attempt, error) do
    if adopted_obligation?(state, state.agents[name].id) do
      state = update_in(state, [:agents, name], &Map.put(&1, :admission_uncertain, true))

      state =
        reserve_uncertain(
          state,
          name,
          Error.new(:unknown_outcome, "managed child admission acknowledgement is unconfirmed")
        )

      send(self(), {:cleanup_failed_birth, name, attempt.attempt_id})
      {error, state} = reject_admission(state, attempt, :failed, error)
      {:error, error, state}
    else
      fail_legacy_activation(state, name, attempt, error)
    end
  end

  defp fail_legacy_activation(state, name, attempt, error) do
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
           :ok <- retained_child_session(state, attempt.agent_id, opts),
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

  defp settlement_snapshot(%{settlement_evidence: %{settlement_result: {:ok, snapshot}}}),
    do: snapshot

  defp settlement_snapshot(_), do: nil

  defp settled_snapshot(%{admission_uncertain: true}),
    do: {:error, Error.new(:unknown_outcome, "managed child admission is unconfirmed")}

  defp settled_snapshot(%{settlement_evidence: %{settlement_result: result} = evidence}) do
    if confirmed_session_close?(Map.get(evidence, :session_close_result, :not_managed)),
      do: result,
      else: {:error, Error.new(:unknown_outcome, "child Session cleanup is unconfirmed")}
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
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, Error.new(:unknown_outcome, "agent termination is not settled")}
    else
      case GenServer.call(pid, :status, remaining) do
        %{phase: :terminal} = snapshot ->
          {:ok, snapshot}

        %{phase: :storage_failed} ->
          {:error, Error.new(:unknown_outcome, "agent store settlement is uncertain")}

        %{phase: :recovery_required} ->
          {:error, Error.new(:unknown_outcome, "agent requires host recovery")}

        _ ->
          Process.sleep(min(5, max(0, deadline - System.monotonic_time(:millisecond))))
          await_settlement(pid, deadline)
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

  defp cancel_agent(%{settlement_evidence: %{cancel_result: result}}), do: result

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

  defp cancel_owned_tree(state, name, :close) do
    names = [name | descendant_names(state, name)]

    {state, errors} =
      Enum.reduce(names, {state, []}, fn child_name, {acc, errors} ->
        agent = acc.agents[child_name]

        if agent.closure == :confirmed do
          closed = %{agent | status: :shutdown}
          acc = put_in(acc, [:agents, child_name], closed)
          {publish(acc, :closed, child_name), errors}
        else
          acc =
            invalidate_interaction(
              acc,
              child_name,
              Error.new(:resource_conflict, "agent is closing")
            )

          result =
            with :ok <- normalize_cancel(cancel_agent(agent)),
                 {:ok, closed} <- maybe_close_child(acc, agent, :close),
                 do: {:ok, closed}

          case result do
            {:ok, closed} ->
              acc = put_in(acc, [:agents, child_name], %{closed | status: :shutdown})

              acc = %{
                acc
                | monitors: maybe_delete_monitor(acc.monitors, agent.monitor),
                  updates: MapSet.put(acc.updates, child_name)
              }

              {publish(acc, :closed, child_name), errors}

            {:error, %Error{} = error} ->
              acc = put_in(acc, [:agents, child_name, :status], :interrupted)
              {reserve_uncertain(acc, child_name, error), [error | errors]}
          end
        end
      end)

    case errors do
      [] -> {:ok, state}
      [error | _] -> {:error, error, state}
    end
  end

  defp normalize_cancel(:already_closed), do: :ok
  defp normalize_cancel(result), do: result

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

  defp bound_descriptor(operation, state) do
    with %{manager_id: manager, fingerprint: fingerprint} <- operation[:collaboration_binding],
         true <- manager == state.manager_id,
         %{} = descriptor <- state.bound_contracts[fingerprint],
         true <- operation.collaboration_binding == descriptor.collaboration_binding,
         true <- operation[:tool_name] == descriptor.tool_name,
         true <- operation[:tool_revision] == descriptor.tool_revision do
      {:ok, descriptor}
    else
      _ -> {:error, Error.new(:forbidden, "unknown collaboration binding")}
    end
  end

  defp authenticate_native(profile, operation, state) do
    name = state.run_index[operation[:run_id]]

    inherited =
      if name,
        do: [state.agents[name].authority | bound_ancestor_authorities(state, name)],
        else: []

    authorities =
      [
        operation[:effective_authority],
        state.parent_authority,
        state.session_authority | inherited
      ]

    bound_policy =
      Enum.any?(authorities, fn authority ->
        bindings = if is_map(authority), do: Map.get(authority, :tool_bindings), else: nil
        is_map(bindings) and map_size(bindings) > 0
      end)

    cond do
      Map.has_key?(operation, :collaboration_binding) ->
        {:error, Error.new(:forbidden, "bound collaboration requires call_bound/2")}

      bound_policy or (name != nil and Map.has_key?(state.child_sessions, state.agents[name].id)) ->
        wait = %{
          default: state.default_wait_timeout_ms,
          min: state.min_wait_timeout_ms,
          max: state.max_wait_timeout_ms
        }

        contracts =
          case profile do
            :v1 -> v1_contracts(self(), wait)
            :v2 -> v2_contracts(self(), wait)
          end

        attrs =
          Enum.find(
            contracts,
            &(Contract.canonical_name(&1.namespace, &1.name) == operation[:tool_name])
          )

        with {:ok, contract} <- Contract.new(attrs),
             {:ok, owner} <- bound_owner(operation) do
          authenticate_bound(operation, owner, Contract.descriptor(contract), state)
        end

      true ->
        authenticate(operation, state)
    end
  end

  defp authenticate_bound(operation, owner, descriptor, state) do
    checked = put_in(operation, [:backend_context, :resource_owner], owner)

    with {:ok, caller} <- authenticate(checked, state),
         true <-
           operation[:incarnation] == caller.incarnation or
             {:error, Error.new(:forbidden, "stale collaboration incarnation")},
         %{} = effective <- operation[:effective_authority],
         true <-
           (operation[:caller] == effective[:caller] and
              effective[:caller] == bound_current_authority(state, caller)[:caller]) or
             {:error,
              Error.new(:forbidden, "bound collaboration caller does not match authority")},
         true <-
           bound_grants_subset?(effective, bound_current_authority(state, caller)) or
             {:error,
              Error.new(:forbidden, "bound collaboration authority exceeds current grants")},
         :ok <- bound_session_owner(state, caller, owner, operation),
         {:ok, _} <- Policy.authorize_tool(effective, descriptor, operation),
         {:ok, _} <- Policy.authorize_tool(caller.authority, descriptor, operation),
         :ok <- bound_parent_authority(state, descriptor, operation) do
      {:ok, %{caller | authority: bound_delegation_authority(effective, state, caller)}}
    else
      nil -> {:error, Error.new(:forbidden, "bound collaboration requires invocation authority")}
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:forbidden, "bound collaboration authority is invalid")}
    end
  end

  defp bound_current_authority(state, caller) do
    if caller.name == state.parent_name,
      do: state.parent_authority,
      else: state.agents[caller.name].authority
  end

  defp bound_grants_subset?(effective, current) do
    grants = Map.get(effective, :grants, [])
    allowed = Map.get(current, :grants, [])

    is_list(grants) and is_list(allowed) and
      MapSet.subset?(MapSet.new(grants), MapSet.new(allowed))
  end

  defp bound_delegation_authority(effective, state, caller) do
    authorities =
      [
        bound_current_authority(state, caller),
        state.parent_authority,
        state.session_authority
        | bound_ancestor_authorities(state, state.run_index[caller.run_id])
      ]
      |> Enum.reject(&is_nil/1)

    names =
      Enum.filter(effective.grants, fn name ->
        Enum.all?(authorities, fn authority ->
          name in Map.get(authority, :grants, []) and
            tool_revision(authority, name) == tool_revision(effective, name) and
            Map.get(Map.get(authority, :tool_bindings, %{}), name) ==
              Map.get(Map.get(effective, :tool_bindings, %{}), name)
        end)
      end)

    effective
    |> Map.put(:grants, names)
    |> Map.update(:tool_bindings, %{}, &Map.take(&1, names))
    |> Map.update(:tool_revisions, %{}, &Map.take(&1, names))
  end

  defp bound_session_owner(state, caller, owner, operation) do
    valid =
      case owner do
        %{owner_id: id, incarnation: incarnation} ->
          if caller.name == state.parent_name do
            state.session_owner == {id, incarnation}
          else
            agent = state.agents[caller.name]

            case state.child_sessions[agent.id] do
              %{status: :accepted, binding: binding, admission: admission} ->
                id == binding.owner_id and incarnation == binding.incarnation and
                  owner[:owner_pid] == binding.owner_pid and
                  owner[:session_binding] == binding and
                  admission.attempt_id == agent.attempt_id and
                  admission.run_id == agent.run_id and admission.incarnation == agent.incarnation

              nil ->
                is_nil(Keyword.get(agent.opts, :session_binding)) and
                  state.session_owner == {id, incarnation}

              _ ->
                false
            end
          end

        nil when caller.name != state.parent_name ->
          agent = state.agents[caller.name]

          is_nil(Keyword.get(agent.opts, :session_binding)) and
            not adopted_obligation?(state, agent.id) and
            agent.pid == get_in(operation, [:backend_context, :resource_owner_pid])

        _ ->
          false
      end

    if valid,
      do: :ok,
      else: {:error, Error.new(:forbidden, "bound collaboration session owner does not match")}
  end

  defp bound_parent_authority(state, descriptor, operation) do
    authorities =
      [
        state.parent_authority,
        state.session_authority
        | bound_ancestor_authorities(state, state.run_index[operation.run_id])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce_while(authorities, :ok, fn authority, :ok ->
      case Policy.authorize_tool(
             Map.put(authority, :run_id, operation.run_id),
             descriptor,
             operation
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bound_ancestor_authorities(_state, nil), do: []

  defp bound_ancestor_authorities(state, name) do
    parent = state.agents[name].parent

    if parent == state.parent_name,
      do: [],
      else: [state.agents[parent].authority | bound_ancestor_authorities(state, parent)]
  end

  defp bound_original_arguments(%{codex_input_kind: :custom}, %{arguments: input})
       when is_binary(input),
       do: {:ok, input}

  defp bound_original_arguments(descriptor, operation),
    do: InputSchema.validate(descriptor.schema, Map.get(operation, :arguments))

  defp bound_action(:spawn), do: {:spawn, :v2}
  defp bound_action(:followup), do: :followup_v2
  defp bound_action(:wait), do: :wait_v2
  defp bound_action(action), do: action

  defp bound_schema(:spawn, _state), do: spawn_schema(:v2)

  defp bound_schema(action, _state) when action in [:message, :followup],
    do: target_message_schema()

  defp bound_schema(:interrupt, _state), do: required_string_schema("target")
  defp bound_schema(:list, _state), do: optional_string_schema("path_prefix")

  defp bound_schema(:wait, state) do
    wait_schema(:v2, %{
      default: state.default_wait_timeout_ms,
      min: state.min_wait_timeout_ms,
      max: state.max_wait_timeout_ms
    })
  end

  defp invocation_summary(operation) do
    operation
    |> Map.take(
      ~w(run_id incarnation step_id attempt_id invocation_id tool_name tool_revision catalog_revision tool_call_id turn_id collaboration_binding)a
    )
    |> Map.put(
      :arguments_digest,
      :crypto.hash(:sha256, :erlang.term_to_binary(operation.arguments, [:deterministic]))
      |> Base.encode16(case: :lower)
    )
  end

  defp notification_sender_owner(%{session_owner: nil}, _sender, _operation), do: :ok

  defp notification_sender_owner(state, sender, operation),
    do:
      bound_session_owner(
        state,
        sender,
        get_in(operation, [:backend_context, :resource_owner]),
        operation
      )

  defp notification_payload(%{id: id, text: text} = value)
       when is_binary(id) and byte_size(id) in 1..256 and is_binary(text) and
              byte_size(text) in 1..8192 do
    try do
      if byte_size(JSON.encode!(Map.get(value, :metadata, %{}))) <= 4096,
        do: :ok,
        else: validation("notification metadata exceeds bound")
    rescue
      _ -> validation("notification metadata must be serializable")
    end
  end

  defp notification_payload(_), do: validation("invalid bounded notification payload")

  defp notification_destination(state, expected) do
    identity = fn id, run, incarnation ->
      expected[:manager_id] == state.manager_id and expected[:agent_id] == id and
        expected[:run_id] == run and expected[:incarnation] == incarnation
    end

    cond do
      expected[:manager_id] != state.manager_id ->
        {:skip, :skipped_stale}

      expected[:agent_id] == state.root_id ->
        cond do
          not identity.(state.root_id, state.parent_run_id, state.parent_incarnation) ->
            {:skip, :skipped_stale}

          not is_pid(state.parent_pid) or state.parent_recovery ->
            {:skip, :skipped_inactive}

          true ->
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

      true ->
        case Enum.find(state.agents, fn {_name, agent} -> agent.id == expected[:agent_id] end) do
          {name, agent} ->
            cond do
              not identity.(agent.id, agent.run_id, agent.incarnation) ->
                {:skip, :skipped_stale}

              agent.status != :running or agent.closure != :open or settling?(state, name) or
                  not is_pid(agent.pid) ->
                {:skip, :skipped_inactive}

              true ->
                {:ok, name,
                 %{
                   pid: agent.pid,
                   identity: %{
                     run_id: agent.run_id,
                     incarnation: agent.incarnation,
                     session_binding: Keyword.get(agent.opts, :session_binding)
                   }
                 }}
            end

          nil ->
            {:skip, :skipped_stale}
        end
    end
  end

  defp publication_within_ancestors?(state, agent, authority) do
    authorities =
      [
        state.parent_authority,
        state.session_authority | bound_ancestor_authorities(state, state.run_index[agent.run_id])
      ]
      |> Enum.reject(&is_nil/1)

    authority.caller == agent.authority.caller and
      Enum.all?(authorities, fn ceiling ->
        Enum.all?(authority.grants, fn name ->
          name in ceiling.grants and
            tool_revision(authority, name) == tool_revision(ceiling, name) and
            get_in(authority, [:tool_bindings, name]) == get_in(ceiling, [:tool_bindings, name])
        end)
      end)
  end

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

        if agent.run_id == run_id and agent.status == :running and agent.closure == :open and
             not settling?(state, name),
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

    bindings = Map.get(parent_authority, :tool_bindings, %{})
    child_bindings = Map.get(child, :tool_bindings, %{})

    inherited =
      Enum.all?(child_grants, fn name ->
        case {Map.get(bindings, name), Map.get(child_bindings, name)} do
          {nil, nil} ->
            true

          {binding, binding} when not is_nil(binding) ->
            tool_revision(child, name) == tool_revision(parent_authority, name)

          _ ->
            false
        end
      end)

    if MapSet.subset?(child_grants, parent_grants) and inherited,
      do: :ok,
      else: {:error, Error.new(:forbidden, "child authority exceeds parent grants")}
  end

  defp tool_revision(authority, name),
    do:
      Map.get(Map.get(authority, :tool_revisions, %{}), name, Map.get(authority, :tool_revision))

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
    if settling?(state, name), do: state, else: settle_available_agent(state, name)
  end

  defp settle_available_agent(state, name) do
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

  defp interrupt_target(state, name, _agent, metadata \\ %{}) do
    state =
      invalidate_interaction(state, name, Error.new(:resource_conflict, "agent is interrupted"))

    agent = state.agents[name]

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
          |> publish(:interrupted, name, metadata)

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

    if Enum.any?(names, &(&1 == caller or reachable?(graph, &1, caller, %{}))),
      do:
        {:error,
         Error.new(:resource_conflict, "collaboration wait would create a dependency cycle")},
      else: :ok
  end

  @spec reachable?(map(), term(), term(), map()) :: boolean()
  defp reachable?(_graph, node, target, _visited) when node == target, do: true

  defp reachable?(graph, node, target, visited) do
    if Map.has_key?(visited, node) do
      false
    else
      graph
      |> Map.get(node, MapSet.new())
      |> Enum.any?(&reachable?(graph, &1, target, Map.put(visited, node, true)))
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
          settling?(state, name) ->
            {:error, settlement_conflict()}

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
            deliver =
              if envelope.kind == :notification,
                do: &Conversation.notify_active/4,
                else: &Conversation.queue_only/4

            deliver.(
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
              {:ok, receipt} ->
                {:ok,
                 Map.put(
                   receipt,
                   :accepted,
                   Map.get(receipt, :status) not in [:skipped_inactive, :skipped_stale]
                 )}

              {:error, error} ->
                {:error, error}
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

    attrs =
      if state.triggering_invocation,
        do: Map.put(attrs, :triggering_invocation, state.triggering_invocation),
        else: attrs

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
    do:
      Map.take(attempt, [
        :attempt_id,
        :agent_id,
        :name,
        :run_id,
        :incarnation,
        :activation,
        :triggering_invocation
      ])

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

    error = %{
      error
      | details:
          Map.merge(error.details, %{
            attempt_id: attempt.attempt_id,
            manager_id: attempt.manager_id
          })
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
      root: %{agent_id: state.root_id},
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
      result_delivery: Map.get(agent, :result_delivery),
      pending_interaction: agent.pending_interaction
    }
  end

  defp publish(state, type, name, metadata \\ %{}) do
    next = %{state | revision: state.revision + 1}

    event =
      %{
        manager_id: next.manager_id,
        revision: next.revision,
        type: type,
        agent: public_agent(next, next.agents[name])
      }
      |> Map.merge(metadata)

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
