defmodule Backplane.AgentRuntime.Kernel do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Deterministic execution kernel for Backplane agent runtime runs.

  External results are accepted only when their run, incarnation, step,
  attempt, invocation, or continuation identities match the authoritative run
  state. Cancellation remains nonterminal until an exact cleanup snapshot is
  confirmed or uncertainty is explicitly retained.
  """

  @terminal_states [:completed, :failed, :cancelled, :timed_out, :unknown_outcome]
  @active_states [:queued, :running, :waiting_approval, :waiting_result]
  @provider_identity [:run_id, :incarnation, :step_id, :attempt_id]
  @tool_identity @provider_identity ++ [:invocation_id]
  @wait_identity [:run_id, :incarnation, :continuation_id, :target_run_id]

  @two_arg_commands [
    :provider_started,
    :provider_completed,
    :tool_invoked,
    :tool_completed,
    :wait_started,
    :wait_resolved,
    :child_settled,
    :cleanup_settled,
    :conversation_updated,
    :finish
  ]
  @one_arg_commands [:start, :cancel, :deadline_exceeded]

  @spec execute(map(), tuple()) :: {:ok, map(), map(), list()} | {:error, Error.t()}
  def execute(run, command) when is_map(run) and is_tuple(command) do
    [kind | rest] = Tuple.to_list(command)

    with {:ok, _revision} <- revision(run),
         {:ok, at} <- occurred_at(List.first(rest)),
         {:ok, input} <- command_input(kind, rest) do
      transition(run, kind, at, input)
    end
  end

  @spec terminal?(atom()) :: boolean()
  def terminal?(state), do: state in @terminal_states

  @doc """
  Returns the exact authoritative work identities a trusted controller must
  reconcile before confirmed cancellation cleanup can settle.
  """
  @spec cleanup_requirements(map()) :: map()
  def cleanup_requirements(run) when is_map(run) do
    %{
      provider: Map.get(run, :active_provider),
      tools:
        run
        |> Map.get(:active_tools, %{})
        |> Map.values()
        |> Enum.map(&Map.take(&1, @tool_identity))
        |> Enum.sort_by(&to_string(&1.invocation_id)),
      children: outstanding_children(run),
      dependencies: Map.get(run, :dependencies, []) |> Enum.uniq() |> Enum.sort()
    }
  end

  # -- dispatch ----------------------------------------------------------------

  # Host-neutral conversational checkpoints share the same revision fence as effects.
  defp transition(run, :conversation_updated, at, input) do
    with :ok <- require_state(run, :running, :conversation_updated),
         :ok <- validate_run_identity(run, input),
         {:ok, conversation} <- required_map(input, :conversation, "conversation") do
      run
      |> Map.put(:context, Map.put(Map.get(run, :context, %{}), :conversation, conversation))
      |> maybe_update_execution_deadline(input)
      |> commit(:running, :conversation_updated, at, input)
    end
  end

  defp transition(run, :finish, at, input) do
    with :ok <- require_state(run, :running, :finish),
         :ok <- validate_run_identity(run, input),
         :ok <- ensure_no_active_provider(run),
         :ok <- ensure_no_unsettled_work(run),
         {:ok, outcome} <- required(input, :outcome, "outcome") do
      status = field(input, :status)

      if status in [:completed, :failed] do
        run |> Map.put(:outcome, outcome) |> commit(status, status, at, outcome)
      else
        validation_error("finish status must be completed or failed")
      end
    end
  end

  defp transition(run, :admit, at, input) do
    if run.state == :queued and not Map.get(run, :admitted, false) do
      admit(run, at, input)
    else
      invalid(run, :admit)
    end
  end

  defp transition(run, :start, at, input) do
    cond do
      run.state == :queued and Map.get(run, :admitted, false) ->
        commit(run, :running, :start, at, input)

      run.state == :running and Map.get(run, :admitted, false) ->
        commit(run, :running, :start, at, input)

      true ->
        invalid(run, :start)
    end
  end

  defp transition(run, :provider_started, at, input) do
    with :ok <- require_state(run, :running, :provider_started),
         :ok <- validate_run_identity(run, input),
         :ok <- ensure_provider_start_allowed(run),
         {:ok, identity} <- identity(input, @provider_identity, "provider"),
         :ok <- ensure_new_provider_attempt(run, identity) do
      run
      |> Map.put(:active_provider, identity)
      |> Map.put(:current_step, Map.take(identity, [:step_id, :attempt_id]))
      |> record_provider_attempt(identity)
      |> record_execution_intent(input)
      |> commit(:running, :provider_started, at, input)
    end
  end

  defp transition(run, :provider_completed, at, input) do
    with :ok <- require_state(run, :running, :provider_completed),
         :ok <- validate_run_identity(run, input),
         {:ok, identity} <- identity(input, @provider_identity, "provider"),
         :ok <- match_identity(Map.get(run, :active_provider), identity, "provider attempt"),
         {:ok, final?} <- required_boolean(input, :final?, "provider final?") do
      complete_provider(run, at, input, final?)
    end
  end

  defp transition(run, :tool_invoked, at, input) do
    with :ok <- require_state(run, :running, :tool_invoked),
         :ok <- validate_run_identity(run, input),
         :ok <- ensure_no_active_provider(run),
         {:ok, identity} <- identity(input, @tool_identity, "tool"),
         :ok <- match_current_step(run, identity),
         :ok <- ensure_new_invocation(run, identity.invocation_id) do
      invocation = Map.merge(input, identity)
      active_tools = Map.put(Map.get(run, :active_tools, %{}), identity.invocation_id, invocation)

      run
      |> Map.put(:active_tools, active_tools)
      |> record_execution_intent(input)
      |> commit(:running, :tool_invoked, at, input)
    end
  end

  defp transition(run, :tool_completed, at, input) do
    with :ok <- require_state(run, :running, :tool_completed),
         :ok <- validate_run_identity(run, input),
         {:ok, identity} <- identity(input, @tool_identity, "tool"),
         {:ok, invocation} <- active_invocation(run, identity.invocation_id),
         :ok <- match_identity(Map.take(invocation, @tool_identity), identity, "tool invocation"),
         {:ok, result} <- required(input, :result, "tool result") do
      active_tools = Map.delete(Map.get(run, :active_tools, %{}), identity.invocation_id)
      tool_results = Map.put(Map.get(run, :tool_results, %{}), identity.invocation_id, result)

      run
      |> Map.put(:active_tools, active_tools)
      |> Map.put(:tool_results, tool_results)
      |> settle_execution_intent("tool:#{identity.invocation_id}", :consumed)
      |> commit(:running, :tool_completed, at, input)
    end
  end

  defp transition(run, :wait_started, at, input) do
    with :ok <- require_state(run, :running, :wait_started),
         :ok <- validate_run_identity(run, input),
         {:ok, identity} <- identity(input, @wait_identity, "wait"),
         :ok <- ensure_no_active_wait(run) do
      dependencies = [identity.target_run_id | Map.get(run, :dependencies, [])] |> Enum.uniq()

      run
      |> Map.put(:active_wait, identity)
      |> Map.put(:dependencies, dependencies)
      |> commit(:waiting_result, :wait_started, at, input)
    end
  end

  defp transition(run, :wait_resolved, at, input) do
    with :ok <- require_state(run, :waiting_result, :wait_resolved),
         :ok <- validate_run_identity(run, input),
         {:ok, identity} <- identity(input, @wait_identity, "wait"),
         :ok <- match_identity(Map.get(run, :active_wait), identity, "continuation"),
         {:ok, result} <- required(input, :result, "wait result") do
      results =
        Map.put(Map.get(run, :continuation_results, %{}), identity.continuation_id, result)

      dependencies = List.delete(Map.get(run, :dependencies, []), identity.target_run_id)

      run
      |> Map.put(:active_wait, nil)
      |> Map.put(:dependencies, dependencies)
      |> Map.put(:continuation_results, results)
      |> commit(:running, :wait_resolved, at, input)
    end
  end

  defp transition(run, :child_settled, at, input) do
    with :ok <- require_state(run, :running, :child_settled),
         :ok <- validate_run_identity(run, input),
         {:ok, child_run_id} <- required(input, :child_run_id, "child run id"),
         :ok <- require_unsettled_child(run, child_run_id) do
      settled_children = [child_run_id | Map.get(run, :settled_children, [])] |> Enum.uniq()

      child_results =
        case fetch_field(input, :result) do
          {:ok, result} -> Map.put(Map.get(run, :child_results, %{}), child_run_id, result)
          :error -> Map.get(run, :child_results, %{})
        end

      run
      |> Map.put(:settled_children, settled_children)
      |> Map.put(:child_results, child_results)
      |> commit(:running, :child_settled, at, input)
    end
  end

  defp transition(run, :cancel, at, input) do
    if run.state in @active_states do
      begin_cancellation(run, :cancelled, at, input)
    else
      invalid(run, :cancel)
    end
  end

  defp transition(run, :deadline_exceeded, at, input) do
    if run.state in @active_states do
      begin_cancellation(run, :deadline_exceeded, at, input)
    else
      invalid(run, :deadline_exceeded)
    end
  end

  defp transition(run, :cleanup_settled, at, input) do
    with :ok <- require_state(run, :cancelling, :cleanup_settled),
         {:ok, certainty} <- cleanup_certainty(input) do
      settle_cleanup(run, at, input, certainty)
    end
  end

  # -- transitions -------------------------------------------------------------

  defp admit(run, at, input) do
    target_state = field(input, :state) || :queued

    if target_state in [:queued, :running] do
      run =
        run
        |> Map.put(:admitted, true)
        |> Map.put(:state, target_state)
        |> Map.put(:input, field(input, :input) || %{})
        |> Map.put(:deadline, field(input, :deadline))
        |> Map.put(:outcome, nil)
        |> Map.put_new(:incarnation, 0)
        |> Map.put_new(:context, %{})
        |> Map.put_new(:active_provider, nil)
        |> Map.put_new(:current_step, nil)
        |> Map.put_new(:active_tools, %{})
        |> Map.put_new(:active_wait, nil)
        |> Map.put_new(:dependencies, [])
        |> Map.put_new(:settled_children, [])
        |> Map.put_new(:continuation_results, %{})
        |> Map.put_new(:tool_results, %{})

      commit(run, target_state, :admitted, at, input)
    else
      validation_error("admission state must be queued or running")
    end
  end

  defp complete_provider(run, at, input, false) do
    with {:ok, result} <- required(input, :result, "provider result"),
         {:ok, context} <- optional_map(input, :context, Map.get(run, :context, %{})) do
      run
      |> Map.put(:active_provider, nil)
      |> Map.put(:last_provider_result, result)
      |> Map.put(:context, context)
      |> settle_execution_intent("provider:#{field(input, :attempt_id)}", :consumed)
      |> commit(:running, :provider_completed, at, input)
    end
  end

  defp complete_provider(run, at, input, true) do
    with :ok <- ensure_no_unsettled_work(run),
         {:ok, outcome} <- required(input, :outcome, "provider outcome"),
         {:ok, context} <- optional_map(input, :context, Map.get(run, :context, %{})) do
      run
      |> Map.put(:active_provider, nil)
      |> Map.put(:current_step, nil)
      |> Map.put(:context, context)
      |> Map.put(:outcome, outcome)
      |> settle_execution_intent("provider:#{field(input, :attempt_id)}", :consumed)
      |> commit(:completed, :completed, at, outcome)
    end
  end

  defp begin_cancellation(run, reason, at, input) do
    run
    |> Map.put(:stop_reason, reason)
    |> Map.put(:cleanup_required, cleanup_requirements(run))
    |> commit(:cancelling, :cancelling, at, input)
  end

  defp settle_cleanup(run, at, input, :confirmed) do
    expected = cleanup_requirements(run)

    if field(input, :settled) == expected do
      terminal = if run.stop_reason == :deadline_exceeded, do: :timed_out, else: :cancelled

      outcome = %{
        "stop_reason" => Atom.to_string(run.stop_reason),
        "cleanup" => %{"certainty" => "confirmed"}
      }

      run
      |> clear_active_work()
      |> settle_started_execution_intents(:cancelled)
      |> Map.put(:outcome, outcome)
      |> commit(terminal, terminal, at, outcome)
    else
      conflict("cleanup settlement does not match authoritative work")
    end
  end

  defp settle_cleanup(run, at, input, :uncertain) do
    with {:ok, evidence} <- required_map(input, :evidence, "cleanup evidence") do
      outcome = %{
        "stop_reason" => Atom.to_string(run.stop_reason),
        "cleanup" => %{"certainty" => "uncertain", "evidence" => deep_stringify_keys(evidence)}
      }

      run
      |> settle_started_execution_intents(:uncertain)
      |> Map.put(:outcome, outcome)
      |> commit(:unknown_outcome, :unknown_outcome, at, outcome)
    end
  end

  defp clear_active_work(run) do
    run
    |> Map.put(:active_provider, nil)
    |> Map.put(:active_tools, %{})
    |> Map.put(:active_wait, nil)
    |> Map.put(:dependencies, [])
    |> Map.put(:settled_children, Map.get(run, :children, []))
  end

  defp commit(run, state, event_kind, at, payload) do
    revision = run.expected_revision + 1
    run = run |> Map.put(:state, state) |> Map.put(:expected_revision, revision)
    event = event(at, "run.#{event_kind}", state, payload)
    {:ok, run, %{expected_revision: revision, state: state, events: [event]}, []}
  end

  # -- fencing -----------------------------------------------------------------

  defp validate_run_identity(run, input) do
    expected = %{run_id: Map.get(run, :run_id), incarnation: Map.get(run, :incarnation, 0)}
    received = %{run_id: field(input, :run_id), incarnation: field(input, :incarnation)}
    match_identity(expected, received, "run incarnation")
  end

  defp match_current_step(run, identity) do
    match_identity(
      Map.get(run, :current_step),
      Map.take(identity, [:step_id, :attempt_id]),
      "provider step"
    )
  end

  defp match_identity(expected, received, kind) do
    if is_map(expected) and expected == received do
      :ok
    else
      conflict("#{kind} identity does not match authoritative state")
    end
  end

  defp ensure_new_invocation(run, invocation_id) do
    if Map.has_key?(Map.get(run, :active_tools, %{}), invocation_id) or
         Map.has_key?(Map.get(run, :tool_results, %{}), invocation_id) do
      conflict("tool invocation is duplicate")
    else
      :ok
    end
  end

  defp active_invocation(run, invocation_id) do
    case Map.fetch(Map.get(run, :active_tools, %{}), invocation_id) do
      {:ok, invocation} -> {:ok, invocation}
      :error -> conflict("tool invocation is not active")
    end
  end

  defp ensure_no_active_wait(run) do
    if is_nil(Map.get(run, :active_wait)),
      do: :ok,
      else: conflict("a continuation is already active")
  end

  defp ensure_provider_start_allowed(run) do
    if map_size(Map.get(run, :active_tools, %{})) == 0 and
         is_nil(Map.get(run, :active_wait)) do
      :ok
    else
      conflict("provider cannot start while tool or continuation work is active")
    end
  end

  defp ensure_new_provider_attempt(run, identity) do
    reservation_id = "provider:#{identity.attempt_id}"
    active_attempt_id = get_in(run, [:active_provider, :attempt_id])

    if active_attempt_id == identity.attempt_id or
         Map.has_key?(Map.get(run, :provider_attempts, %{}), identity.attempt_id) or
         Map.has_key?(Map.get(run, :execution_intents, %{}), reservation_id) do
      conflict("provider attempt was already accepted")
    else
      :ok
    end
  end

  defp record_provider_attempt(run, identity) do
    Map.update(run, :provider_attempts, %{identity.attempt_id => identity}, fn attempts ->
      Map.put(attempts, identity.attempt_id, identity)
    end)
  end

  defp ensure_no_active_provider(run) do
    if is_nil(Map.get(run, :active_provider)),
      do: :ok,
      else: conflict("tool cannot start while a provider attempt is active")
  end

  defp record_execution_intent(run, input) do
    case {fetch_field(input, :execution_intent), fetch_field(input, :execution_budget)} do
      {{:ok, %{reservation: %{reservation_id: reservation_id}} = intent}, {:ok, budget}}
      when is_binary(reservation_id) and is_map(budget) ->
        run
        |> Map.put(:execution_budget, budget)
        |> Map.update(:execution_intents, %{reservation_id => intent}, fn intents ->
          Map.put(intents, reservation_id, intent)
        end)
        |> maybe_put_execution_deadline(input)

      _ ->
        run
    end
  end

  defp maybe_put_execution_deadline(run, input) do
    case {Map.get(run, :deadline), fetch_field(input, :execution_deadline)} do
      {nil, {:ok, deadline}} when is_integer(deadline) -> Map.put(run, :deadline, deadline)
      _ -> run
    end
  end

  defp settle_execution_intent(run, reservation_id, status) do
    with {:ok, intents} <- Map.fetch(run, :execution_intents),
         {:ok, intent} <- Map.fetch(intents, reservation_id) do
      Map.put(
        run,
        :execution_intents,
        Map.put(intents, reservation_id, Map.put(intent, :status, status))
      )
    else
      :error -> run
    end
  end

  defp settle_started_execution_intents(run, status) do
    case Map.fetch(run, :execution_intents) do
      {:ok, intents} ->
        updated =
          Map.new(intents, fn {reservation_id, intent} ->
            updated =
              if Map.get(intent, :status) == :started,
                do: Map.put(intent, :status, status),
                else: intent

            {reservation_id, updated}
          end)

        Map.put(run, :execution_intents, updated)

      :error ->
        run
    end
  end

  defp require_unsettled_child(run, child_run_id) do
    cond do
      child_run_id not in Map.get(run, :children, []) ->
        conflict("child is not owned by this run")

      child_run_id in Map.get(run, :settled_children, []) ->
        conflict("child is already settled")

      true ->
        :ok
    end
  end

  defp ensure_no_unsettled_work(run) do
    unsettled? =
      map_size(Map.get(run, :active_tools, %{})) > 0 or
        not is_nil(Map.get(run, :active_wait)) or
        Map.get(run, :dependencies, []) != [] or
        outstanding_children(run) != []

    if unsettled?, do: conflict("required work remains unsettled"), else: :ok
  end

  defp outstanding_children(run) do
    Map.get(run, :children, []) -- Map.get(run, :settled_children, [])
  end

  # -- validation --------------------------------------------------------------

  defp require_state(run, expected, kind) do
    if run.state == expected, do: :ok, else: invalid(run, kind)
  end

  defp invalid(run, kind) do
    {:error,
     Error.new(:validation, "command is invalid in the current run state",
       details: %{state: run.state, command: kind}
     )}
  end

  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}

  defp revision(%{expected_revision: revision}) when is_integer(revision) and revision >= 0,
    do: {:ok, revision}

  defp revision(_run), do: validation_error("run expected revision is required")

  defp occurred_at(at) when is_integer(at) and at >= 0, do: {:ok, at}
  defp occurred_at(_at), do: validation_error("command timestamp is required")

  defp command_input(:admit, [_, input]) when is_map(input), do: {:ok, input}
  defp command_input(:admit, _), do: validation_error("admit input is required")
  defp command_input(kind, [_]) when kind in @one_arg_commands, do: {:ok, %{}}

  defp command_input(kind, [_, input]) when kind in @two_arg_commands and is_map(input),
    do: validate_command_input(kind, input)

  defp command_input(kind, [_, _]) when kind in @two_arg_commands,
    do: validation_error("#{kind} input must be a map")

  defp command_input(_kind, _), do: validation_error("command arity is invalid")

  defp validate_command_input(kind, input) when kind in [:conversation_updated, :finish] do
    with {:ok, _} <- identity(input, [:run_id, :incarnation], "conversation"), do: {:ok, input}
  end

  defp validate_command_input(:provider_started, input) do
    with {:ok, _} <- identity(input, @provider_identity, "provider"), do: {:ok, input}
  end

  defp validate_command_input(:provider_completed, input) do
    with {:ok, _} <- identity(input, @provider_identity, "provider"),
         {:ok, _} <- required_boolean(input, :final?, "provider final?") do
      {:ok, input}
    end
  end

  defp validate_command_input(:tool_invoked, input) do
    with {:ok, _} <- identity(input, @tool_identity, "tool"),
         {:ok, _} <- required(input, :tool_name, "tool name"),
         {:ok, _} <- required(input, :tool_revision, "tool revision"),
         {:ok, _} <- required_map(input, :arguments, "tool arguments") do
      {:ok, input}
    end
  end

  defp validate_command_input(:tool_completed, input) do
    with {:ok, _} <- identity(input, @tool_identity, "tool"),
         {:ok, _} <- required(input, :result, "tool result") do
      {:ok, input}
    end
  end

  defp validate_command_input(:wait_started, input) do
    with {:ok, _} <- identity(input, @wait_identity, "wait"), do: {:ok, input}
  end

  defp validate_command_input(:wait_resolved, input) do
    with {:ok, _} <- identity(input, @wait_identity, "wait"),
         {:ok, _} <- required(input, :result, "wait result") do
      {:ok, input}
    end
  end

  defp validate_command_input(:child_settled, input) do
    with {:ok, _} <- identity(input, [:run_id, :incarnation], "child"),
         {:ok, _} <- required(input, :child_run_id, "child run id") do
      {:ok, input}
    end
  end

  defp validate_command_input(:cleanup_settled, input) do
    with {:ok, _} <- cleanup_certainty(input), do: {:ok, input}
  end

  defp identity(input, keys, kind) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, identity} ->
      case required(input, key, "#{kind} #{key}") do
        {:ok, value} -> {:cont, {:ok, Map.put(identity, key, value)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp required(input, key, label) do
    case fetch_field(input, key) do
      {:ok, nil} -> validation_error("#{label} is required")
      {:ok, value} -> {:ok, value}
      :error -> validation_error("#{label} is required")
    end
  end

  defp required_boolean(input, key, label) do
    case required(input, key, label) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> validation_error("#{label} must be a boolean")
      error -> error
    end
  end

  defp required_map(input, key, label) do
    case required(input, key, label) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> validation_error("#{label} must be a map")
      error -> error
    end
  end

  defp optional_map(input, key, default) do
    case fetch_field(input, key) do
      :error -> {:ok, default}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> validation_error("#{key} must be a map")
    end
  end

  defp cleanup_certainty(input) do
    case field(input, :certainty) do
      certainty when certainty in [:confirmed, "confirmed"] -> {:ok, :confirmed}
      certainty when certainty in [:uncertain, "uncertain"] -> {:ok, :uncertain}
      _ -> validation_error("cleanup certainty must be confirmed or uncertain")
    end
  end

  defp field(input, key) do
    case fetch_field(input, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_field(input, key) do
    case Map.fetch(input, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(input, Atom.to_string(key))
    end
  end

  defp validation_error(message), do: {:error, Error.new(:validation, message)}

  defp maybe_update_execution_deadline(run, input) do
    case fetch_field(input, :execution_deadline) do
      {:ok, deadline} when is_integer(deadline) ->
        if deadline >= Map.get(run, :deadline, 0),
          do: Map.put(run, :deadline, deadline),
          else: run

      _ ->
        run
    end
  end

  defp deep_stringify_keys(term) when is_map(term) do
    Map.new(term, fn {key, value} ->
      key = if is_atom(key) and not is_boolean(key), do: Atom.to_string(key), else: key
      {key, deep_stringify_keys(value)}
    end)
  end

  defp deep_stringify_keys(term) when is_list(term), do: Enum.map(term, &deep_stringify_keys/1)
  defp deep_stringify_keys(term), do: term

  defp event(at, type, state, payload) do
    %{
      event_id: "",
      aggregate_id: "",
      sequence: 0,
      schema_version: 1,
      type: type,
      occurred_at: at,
      causation_id: nil,
      payload: %{"state" => state, "input" => payload}
    }
  end
end
