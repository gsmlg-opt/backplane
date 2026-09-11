defmodule Backplane.AgentRuntime.Kernel do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Deterministic execution kernel for Backplane agent runtime runs.

  Transforms state + command + event into new state + transitions + effects.
  """

  @run_states [
    :queued,
    :running,
    :waiting_approval,
    :waiting_result,
    :cancelling,
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :unknown_outcome
  ]

  @terminal_states [:completed, :failed, :cancelled, :timed_out, :unknown_outcome]
  @active_states [:queued, :running, :waiting_approval, :waiting_result]

  @two_arg_commands [
    :provider_started,
    :provider_completed,
    :tool_invoked,
    :tool_completed,
    :wait_started,
    :wait_resolved
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
  def terminal?(state) when state in @terminal_states, do: true
  def terminal?(_), do: false

  # -- dispatch ----------------------------------------------------------------
  defp transition(run, :admit, at, input) do
    if run.state == :queued do
      do_transition(run, :admit, at, input)
    else
      invalid(run, :admit)
    end
  end

  defp transition(run, :start, at, input), do: require_state(run, :running, :start, at, input)

  defp transition(run, :provider_started, at, input),
    do: require_state(run, :running, :provider_started, at, input)

  defp transition(run, :provider_completed, at, input),
    do: require_state(run, :running, :provider_completed, at, input)

  defp transition(run, :tool_invoked, at, input),
    do: require_state(run, :running, :tool_invoked, at, input)

  defp transition(run, :tool_completed, at, input),
    do: require_state(run, :running, :tool_completed, at, input)

  defp transition(run, :wait_started, at, input),
    do: require_state(run, :running, :wait_started, at, input)

  defp transition(run, :wait_resolved, at, input),
    do: require_state(run, :waiting_result, :wait_resolved, at, input)

  defp transition(run, :cancel, at, input) do
    if run.state in @active_states do
      do_transition(run, :cancelling, at, input)
    else
      invalid(run, :cancel)
    end
  end

  defp transition(run, :deadline_exceeded, at, input) do
    if run.state in @active_states or run.state == :cancelling do
      do_transition(run, :timed_out, at, input)
    else
      invalid(run, :deadline_exceeded)
    end
  end

  # -- guards ------------------------------------------------------------------
  defp require_state(run, expected, kind, at, input) do
    if run.state == expected do
      do_transition(run, kind, at, input)
    else
      invalid(run, kind)
    end
  end

  defp invalid(run, kind) do
    {:error,
     Error.new(:validation, "command is invalid in the current run state",
       details: %{state: run.state, command: kind}
     )}
  end

  # -- transitions -------------------------------------------------------------
  defp do_transition(run, :admit, at, input) do
    run_input = Map.get(input, :input, %{})
    target_state = Map.get(input, :state) || :queued

    run =
      run
      |> Map.put(:state, target_state)
      |> Map.put(:input, run_input)
      |> Map.put(:deadline, Map.get(input, :deadline))
      |> Map.put(:outcome, nil)

    new_revision = run.expected_revision + 1
    run = Map.put(run, :expected_revision, new_revision)

    event = event(at, "run.admitted", run.state, run_input)
    {:ok, run, new_transition(new_revision, run.state, [event]), []}
  end

  defp do_transition(run, :provider_completed, at, input) do
    outcome = Map.get(input, :outcome) || Map.get(input, "outcome") || input
    run = %{run | state: :completed, outcome: outcome}
    event = event(at, "run.completed", :completed, outcome)
    new_revision = run.expected_revision + 1
    run = Map.put(run, :expected_revision, new_revision)
    {:ok, run, new_transition(new_revision, :completed, [event]), []}
  end

  defp do_transition(run, state, at, input) do
    run = %{run | state: normalize_state(state)}

    run =
      if state == :wait_resolved,
        do: %{run | outcome: deep_stringify_keys(input)},
        else: run

    event = event(at, "run.#{state}", state, input)
    new_revision = run.expected_revision + 1
    run = Map.put(run, :expected_revision, new_revision)
    {:ok, run, new_transition(new_revision, state, [event]), []}
  end

  defp normalize_state(:start), do: :running
  defp normalize_state(:provider_started), do: :running
  defp normalize_state(:tool_invoked), do: :running
  defp normalize_state(:tool_completed), do: :running
  defp normalize_state(:wait_started), do: :waiting_result
  defp normalize_state(:wait_resolved), do: :completed
  defp normalize_state(state), do: state

  defp deep_stringify_keys(term) when is_map(term) do
    Map.new(term, fn {key, value} ->
      key = if is_atom(key) and not is_boolean(key), do: Atom.to_string(key), else: key
      {key, deep_stringify_keys(value)}
    end)
  end

  defp deep_stringify_keys(term) when is_list(term), do: Enum.map(term, &deep_stringify_keys/1)
  defp deep_stringify_keys(term), do: term

  defp new_transition(expected_revision, state, events) do
    %{expected_revision: expected_revision, state: state, events: events}
  end

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

  # -- validation --------------------------------------------------------------
  defp revision(%{expected_revision: revision}) when is_integer(revision) and revision >= 0,
    do: {:ok, revision}

  defp revision(_run), do: {:error, Error.new(:validation, "run expected revision is required")}

  defp occurred_at(at) when is_integer(at) and at >= 0, do: {:ok, at}
  defp occurred_at(_at), do: {:error, Error.new(:validation, "command timestamp is required")}

  defp command_input(:admit, [_, input]), do: admit_input(input)
  defp command_input(:admit, _), do: validation_error("admit input is required")
  defp command_input(:cancel, [_]), do: {:ok, %{}}
  defp command_input(:deadline_exceeded, [_]), do: {:ok, %{}}

  defp command_input(kind, [_, input]) when kind in @two_arg_commands,
    do: input_input(kind, input)

  defp command_input(kind, [_]) when kind in @two_arg_commands,
    do: validation_error("#{kind} input is required")

  defp command_input(kind, [_]) when kind in @one_arg_commands, do: {:ok, %{}}
  defp command_input(_kind, _), do: validation_error("command arity is invalid")

  defp input_input(kind, input) when is_map(input) do
    case kind do
      :tool_invoked -> validate_tool_invocation(input)
      :tool_completed -> validate_tool_completion(input)
      :wait_started -> validate_wait(input)
      :wait_resolved -> validate_wait_resolution(input)
      :provider_started -> validate_provider(input)
      :provider_completed -> validate_provider(input)
      _ -> validation_error("invalid command")
    end
  end

  defp input_input(kind, _input) do
    {:error, Error.new(:validation, "#{kind} input must be a map")}
  end

  defp admit_input(input) when is_map(input) do
    with {:ok, state} <- optional_state(input),
         {:ok, run_input} <- optional_run_input(input) do
      {:ok,
       %{
         state: state,
         input: run_input,
         deadline: Map.get(input, :deadline) || Map.get(input, "deadline")
       }}
    end
  end

  defp admit_input(_input), do: {:error, Error.new(:validation, "admit input must be a map")}

  defp optional_state(input) do
    state = Map.get(input, :state) || Map.get(input, "state")

    if state in @run_states or is_nil(state),
      do: {:ok, state},
      else: validation_error("invalid run state")
  end

  defp optional_run_input(input) do
    run_input = Map.get(input, :input) || Map.get(input, "input")

    if is_map(run_input) or is_nil(run_input),
      do: {:ok, run_input || %{}},
      else: validation_error("run input must be a map")
  end

  defp validate_tool_invocation(input) do
    with {:ok, _} <- validate_required(input, :invocation_id, "tool"),
         {:ok, _} <- validate_required(input, :run_id, "tool"),
         {:ok, _} <- validate_required(input, :tool_name, "tool"),
         {:ok, _} <- validate_required(input, :tool_revision, "tool") do
      {:ok, input}
    end
  end

  defp validate_tool_completion(input) do
    with {:ok, _} <- validate_required(input, :invocation_id, "tool"),
         {:ok, _} <- validate_required(input, :result, "tool") do
      {:ok, input}
    end
  end

  defp validate_wait(input) do
    with {:ok, _} <- validate_required(input, :target_run_id, "wait") do
      {:ok, input}
    end
  end

  defp validate_wait_resolution(input) do
    with {:ok, _} <- validate_required(input, :target_run_id, "wait"),
         {:ok, _} <- validate_required(input, :result, "wait") do
      {:ok, input}
    end
  end

  defp validate_provider(input) do
    with {:ok, _} <- validate_required(input, :step_id, "provider"),
         {:ok, _} <- validate_required(input, :attempt_id, "provider") do
      {:ok, input}
    end
  end

  defp validate_required(input, key, kind) when is_map(input) do
    value = input[key] || input[Atom.to_string(key)]

    cond do
      not Map.has_key?(input, key) and not Map.has_key?(input, Atom.to_string(key)) ->
        validation_error("#{kind} #{key} is required")

      value == nil ->
        validation_error("#{kind} #{key} is required")

      true ->
        {:ok, value}
    end
  end

  defp validation_error(message) do
    {:error, Error.new(:validation, message)}
  end
end
