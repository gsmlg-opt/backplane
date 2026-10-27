defmodule Backplane.AgentRuntime.Goal.State do
  @moduledoc """
  Pure thread goal transitions and committed, idempotent accounting.

  Public response maps use Backplane's snake_case field names, normalizing
  Codex's camelCase wire protocol. Completion steering references these emitted
  names. Snapshots retain private identities and accounting fences.
  """
  alias Backplane.AgentRuntime.{Error, Usage}

  @statuses [:active, :complete, :paused, :blocked, :budget_limited, :usage_limited]
  @events [
    :turn_started,
    :usage,
    :tool_finished,
    :item_completed,
    :turn_stopped,
    :turn_aborted,
    :turn_error
  ]
  @completion_report "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.token_budget` is present, include token usage from `goal.tokens_used` and `goal.token_budget`. If `goal.time_used_seconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language."

  def new(thread_id, opts) when is_binary(thread_id) and thread_id != "" do
    {:ok,
     %{
       thread_id: thread_id,
       revision: 0,
       goal: nil,
       receipts: %{},
       runtime_receipt_counts: %{},
       admission_settlements: %{},
       invocations: %{},
       deliveries: %{},
       continuation_deferral: nil,
       interrupted_turn: nil,
       accounting_uncertain: false,
       usage: elem(Usage.new(), 1),
       baselines: %{},
       usage_baselines: %{},
       usage_snapshots: %{},
       turns: %{},
       event_revisions: %{},
       failure_turns: 0,
       empty_turns: 0,
       budget_steering_sent: false,
       max_goal_token_budget: Keyword.get(opts, :max_goal_token_budget)
     }}
  end

  def new(_, _), do: error(:validation, "thread_id is required")

  def snapshot(state), do: state

  def create(state, attrs) do
    attrs = normalize(attrs)

    cond do
      state.goal != nil and state.goal.status != :complete ->
        error(:resource_conflict, "an unfinished goal exists")

      not valid_objective?(attrs[:objective]) ->
        error(:validation, "objective is required")

      not valid_budget?(attrs[:token_budget], state.max_goal_token_budget) ->
        error(:validation, "invalid token budget")

      true ->
        now = System.system_time(:millisecond)

        goal = %{
          thread_id: state.thread_id,
          goal_id: Base.encode16(:crypto.strong_rand_bytes(16)),
          objective: attrs.objective,
          status: :active,
          token_budget: attrs[:token_budget],
          tokens_used: 0,
          time_used_seconds: 0,
          created_at_ms: now,
          updated_at_ms: now
        }

        {:ok,
         %{
           state
           | goal: goal,
             accounting_uncertain: false,
             baselines: %{},
             usage_baselines: %{},
             usage_snapshots: %{},
             turns: %{},
             usage: elem(Usage.new(), 1),
             failure_turns: 0,
             empty_turns: 0,
             continuation_deferral: nil,
             interrupted_turn: nil,
             budget_steering_sent: false
         }}
    end
  end

  def update(%{goal: nil}, _, _), do: error(:not_found, "no goal exists")

  def update(state, actor, attrs) when actor in [:model, :host] do
    attrs = normalize(attrs)
    status = status(attrs[:status] || state.goal.status)

    cond do
      status not in @statuses ->
        error(:validation, "invalid goal status")

      actor == :model and
          (status not in [:complete, :blocked, :paused] or Map.has_key?(attrs, :objective) or
             Map.has_key?(attrs, :token_budget)) ->
        error(:validation, "model may only complete, block or pause")

      Map.has_key?(attrs, :objective) and not valid_objective?(attrs.objective) ->
        error(:validation, "objective is required")

      Map.has_key?(attrs, :token_budget) and
          not valid_budget?(attrs.token_budget, state.max_goal_token_budget) ->
        error(:validation, "invalid token budget")

      true ->
        goal = Map.merge(state.goal, Map.take(attrs, [:objective, :token_budget]))
        goal = %{goal | status: status, updated_at_ms: System.system_time(:millisecond)}
        goal = enforce_budget(goal)
        reset = actor == :host and status == :active

        {:ok,
         %{
           state
           | goal: goal,
             failure_turns: if(reset, do: 0, else: state.failure_turns),
             empty_turns: if(reset, do: 0, else: state.empty_turns),
             interrupted_turn: if(reset, do: nil, else: state.interrupted_turn),
             turns:
               if(reset and state.interrupted_turn != nil,
                 do: Map.delete(state.turns, state.interrupted_turn),
                 else: state.turns
               ),
             continuation_deferral: if(actor == :host, do: nil, else: state.continuation_deferral)
         }}
    end
  end

  def update(_, _, _), do: error(:forbidden, "invalid goal actor")

  def clear(state),
    do:
      {:ok,
       %{
         state
         | goal: nil,
           turns: %{},
           interrupted_turn: nil,
           continuation_deferral: %{reason: :cleared}
       }}

  def response(state) do
    goal =
      if state.goal do
        state.goal
        |> Map.take([
          :thread_id,
          :objective,
          :status,
          :token_budget,
          :tokens_used,
          :time_used_seconds
        ])
        |> Map.put(:created_at, div(state.goal.created_at_ms, 1000))
        |> Map.put(:updated_at, div(state.goal.updated_at_ms, 1000))
      end

    response = %{
      goal: goal,
      remaining_tokens:
        if((not state.accounting_uncertain and goal) && goal.token_budget,
          do: max(0, goal.token_budget - goal.tokens_used)
        ),
      completion_budget_report:
        if(
          (not state.accounting_uncertain and goal) && goal.status == :complete &&
            (goal.token_budget != nil or goal.time_used_seconds > 0),
          do: @completion_report
        )
    }

    if state.accounting_uncertain,
      do: Map.put(response, :accounting_uncertain, true),
      else: response
  end

  @doc false
  def cancel_admission(%{goal: goal} = state, admission) when is_map(goal) do
    {:ok,
     %{
       state
       | continuation_deferral:
           admission
           |> Map.take([:run_id, :turn_id, :incarnation, :host_generation, :reservation_token])
           |> Map.put(:reason, :cancelled)
     }}
  end

  def cancel_admission(_, _), do: error(:resource_conflict, "goal identity changed")

  def continuable?(state),
    do:
      state.goal != nil and state.goal.status == :active and state.continuation_deferral == nil and
        (state.goal.token_budget == nil or not state.accounting_uncertain)

  def account(state, receipt) when is_map(receipt) do
    receipt = Map.drop(receipt, [:binding])

    with :ok <- validate_receipt(state, receipt) do
      digest = digest(receipt)

      case state.receipts[receipt.receipt_id] do
        ^digest ->
          {:ok, state}

        nil ->
          with {:ok, next} <- apply_event(state, receipt) do
            key = {receipt.run_id, receipt.incarnation}

            counts = Map.update(Map.get(next, :runtime_receipt_counts, %{}), key, 1, &(&1 + 1))

            {:ok,
             %{
               next
               | receipts: Map.put(next.receipts, receipt.receipt_id, digest),
                 event_revisions: Map.put(next.event_revisions, key, receipt.revision)
             }
             |> Map.put(:runtime_receipt_counts, counts)}
          end

        _ ->
          error(:resource_conflict, "goal receipt conflict")
      end
    end
  end

  def account(_, _), do: error(:validation, "invalid goal receipt")

  defp validate_receipt(state, receipt) do
    key = {receipt[:run_id], receipt[:incarnation]}

    cond do
      state.goal == nil or receipt[:expected_goal_id] != state.goal.goal_id ->
        error(:resource_conflict, "goal identity changed")

      receipt[:thread_id] != state.thread_id ->
        error(:forbidden, "goal thread mismatch")

      not is_binary(receipt[:receipt_id]) or receipt.receipt_id == "" or
        not is_binary(receipt[:run_id]) or not is_binary(receipt[:turn_id]) or
        not is_integer(receipt[:incarnation]) or receipt.incarnation < 0 or
        not is_integer(receipt[:revision]) or receipt.revision < 1 or
        receipt[:type] not in @events or not is_map(receipt[:payload]) ->
        error(:validation, "invalid committed goal receipt")

      receipt.revision < Map.get(state.event_revisions, key, 0) and
          not Map.has_key?(state.receipts, receipt.receipt_id) ->
        error(:resource_conflict, "stale goal event revision")

      true ->
        :ok
    end
  end

  defp apply_event(state, %{type: :turn_started, payload: %{mode: :plan}} = event),
    do:
      {:ok,
       %{state | turns: Map.put(state.turns, turn_key(event), %{default_turn() | mode: :plan})}}

  defp apply_event(state, %{type: :turn_stopped, payload: %{mode: :plan}} = event),
    do: {:ok, %{state | turns: Map.delete(state.turns, turn_key(event))}}

  defp apply_event(state, %{type: type, payload: %{mode: :plan}}) when type != :usage,
    do: {:ok, state}

  defp apply_event(state, %{type: :turn_started} = event) do
    turn = %{
      mode: event.payload[:mode] || :execution,
      automatic: event.payload[:trigger] == :goal,
      activity: false,
      empty_final: false,
      failed_exec: false,
      success: false
    }

    state =
      if state.interrupted_turn do
        %{
          state
          | turns: Map.delete(state.turns, state.interrupted_turn),
            interrupted_turn: nil,
            empty_turns: 0
        }
      else
        state
      end

    state = %{state | turns: Map.put(state.turns, turn_key(event), turn)}
    baseline = event.payload[:usage_baseline]

    state =
      if is_map(baseline) and baseline[:attempt_id],
        do: %{
          state
          | baselines: Map.put(state.baselines, attempt_key(event, baseline), metrics(baseline))
        },
        else: state

    {:ok, state}
  end

  defp apply_event(state, %{type: :usage} = event) do
    payload = event.payload
    values = metrics(payload)
    identity = usage_identity(event)

    snapshot_digest =
      digest({values, payload[:occupancy_tokens] || :unknown, payload[:cumulative] == true})

    with :ok <- validate_usage(payload) do
      case state.usage_snapshots[identity] do
        ^snapshot_digest -> {:ok, state}
        nil -> account_usage(state, event, values, identity, snapshot_digest)
        _ -> error(:resource_conflict, "usage report conflict")
      end
    end
  end

  defp apply_event(state, %{type: :tool_finished} = event) do
    p = event.payload

    state =
      update_turn(state, event, fn turn ->
        %{
          turn
          | activity: true,
            success: turn.success or p[:success] == true,
            failed_exec:
              turn.failed_exec or
                (p[:tool] in ["exec", :exec] and p[:success] == false and
                   p[:handler_executed] == true and p[:namespace] in [nil, :default, "default"])
        }
      end)

    {:ok,
     %{
       state
       | empty_turns: 0,
         failure_turns: if(p[:success] == true, do: 0, else: state.failure_turns)
     }}
  end

  defp apply_event(state, %{type: :item_completed} = event) do
    p = event.payload
    text = p[:text] || ""

    activity =
      case p[:kind] do
        :assistant -> String.trim(text) != "" or p[:questions] != nil
        :reasoning -> String.trim(text) != ""
        _ -> p[:kind] in [:tool, :user, :plan, :command, :extension, :compaction]
      end

    state =
      update_turn(state, event, fn turn ->
        %{
          turn
          | activity: turn.activity or activity,
            empty_final:
              turn.empty_final or
                (p[:kind] == :assistant and not activity and
                   p[:phase] in [nil, :final, :final_answer])
        }
      end)

    {:ok, %{state | empty_turns: if(activity, do: 0, else: state.empty_turns)}}
  end

  defp apply_event(state, %{type: :turn_error, payload: %{retryable: true, exhausted: false}}),
    do: {:ok, state}

  defp apply_event(%{goal: %{status: status}} = state, %{type: :turn_error})
       when status != :active,
       do: {:ok, state}

  defp apply_event(state, %{type: :turn_error} = event) do
    status =
      if event.payload[:class] in [:usage_limit, :usage_limited],
        do: :usage_limited,
        else: :blocked

    {:ok, %{state | goal: enforce_budget(%{state.goal | status: status})}}
  end

  defp apply_event(state, %{type: :turn_aborted} = event) do
    interrupted = event.payload[:reason] in [:interrupt_turn, :interrupted]

    {:ok,
     %{
       state
       | interrupted_turn: if(interrupted, do: turn_key(event)),
         turns: if(interrupted, do: state.turns, else: Map.delete(state.turns, turn_key(event))),
         empty_turns: if(interrupted, do: state.empty_turns, else: 0),
         continuation_deferral: %{
           reason: event.payload[:reason] || :aborted,
           run_id: event.run_id
         }
     }}
  end

  defp apply_event(state, %{type: :turn_stopped} = event) do
    turn = Map.get(state.turns, turn_key(event), default_turn())
    state = finish_audit(state, turn, false)
    {:ok, %{state | turns: Map.delete(state.turns, turn_key(event))}}
  end

  defp account_usage(state, event, values, identity, snapshot_digest) do
    payload = event.payload
    key = attempt_key(event, payload)
    cumulative = payload[:cumulative] == true
    previous = Map.get(state.baselines, key, zero_metrics())
    goal_delta = if cumulative, do: delta(values, previous), else: values
    charge = charge(goal_delta)
    usage_previous = Map.get(state.usage_baselines, key, zero_metrics())
    usage_delta = if cumulative, do: delta(values, usage_previous), else: values
    report = payload |> Map.merge(usage_delta) |> Map.put(:identity, identity)

    with {:ok, usage, _} <- Usage.report(state.usage, report) do
      turn = Map.get(state.turns, turn_key(event), %{})
      plan = turn[:mode] == :plan or payload[:mode] == :plan

      goal =
        if plan or charge == :unknown,
          do: state.goal,
          else: %{state.goal | tokens_used: state.goal.tokens_used + charge}

      {:ok,
       %{
         state
         | usage: usage,
           goal: enforce_budget(goal),
           usage_snapshots: Map.put(state.usage_snapshots, identity, snapshot_digest),
           accounting_uncertain: state.accounting_uncertain or (not plan and charge == :unknown),
           baselines:
             if(cumulative and charge != :unknown and not plan,
               do: Map.put(state.baselines, key, values),
               else: state.baselines
             ),
           usage_baselines:
             if(cumulative,
               do: Map.put(state.usage_baselines, key, merge_known(usage_previous, values)),
               else: state.usage_baselines
             )
       }}
    end
  end

  defp zero_metrics,
    do: %{input_tokens: 0, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0}

  defp merge_known(previous, values),
    do:
      Map.new(values, fn {key, value} ->
        {key, if(is_integer(value), do: value, else: previous[key])}
      end)

  def evaluate_idle(%{interrupted_turn: nil} = state), do: {:ok, state}

  def evaluate_idle(state) do
    turn = Map.get(state.turns, state.interrupted_turn, default_turn())
    state = finish_empty_audit(state, turn, true)

    {:ok,
     %{state | turns: Map.delete(state.turns, state.interrupted_turn), interrupted_turn: nil}}
  end

  defp finish_audit(state, turn, interrupted) do
    failures =
      if turn.failed_exec and not turn.success,
        do: state.failure_turns + 1,
        else: state.failure_turns

    goal =
      if failures >= 3 and state.goal.status == :active,
        do: enforce_budget(%{state.goal | status: :blocked}),
        else: state.goal

    finish_empty_audit(%{state | failure_turns: failures, goal: goal}, turn, interrupted)
  end

  defp finish_empty_audit(state, turn, interrupted) do
    empty = turn.automatic and not turn.activity and (turn.empty_final or interrupted)
    empties = if empty, do: state.empty_turns + 1, else: 0

    goal =
      if empties >= 3 and state.goal != nil and state.goal.status == :active,
        do: enforce_budget(%{state.goal | status: :blocked}),
        else: state.goal

    %{state | empty_turns: empties, goal: goal}
  end

  defp update_turn(state, event, fun),
    do: %{state | turns: Map.update(state.turns, turn_key(event), fun.(default_turn()), fun)}

  defp default_turn,
    do: %{
      mode: :execution,
      automatic: false,
      activity: false,
      empty_final: false,
      failed_exec: false,
      success: false
    }

  defp turn_key(event), do: {event.run_id, event.incarnation, event.turn_id}
  defp attempt_key(event, payload), do: {event.run_id, event.incarnation, payload[:attempt_id]}

  defp usage_identity(event),
    do:
      :erlang.term_to_binary(
        {event.run_id, event.incarnation, event.payload[:attempt_id], event.payload[:identity]}
      )
      |> Base.encode64()

  defp validate_usage(payload) do
    ids =
      Enum.all?([:identity, :attempt_id], fn key ->
        is_binary(payload[key]) and payload[key] != ""
      end)

    values =
      Enum.all?([:input_tokens, :cached_tokens, :output_tokens, :reasoning_tokens], fn key ->
        value = payload[key]
        is_nil(value) or value == :unknown or (is_integer(value) and value >= 0)
      end)

    if ids and values, do: :ok, else: error(:validation, "invalid goal usage envelope")
  end

  defp metrics(payload),
    do:
      Map.new([:input_tokens, :cached_tokens, :output_tokens], fn key ->
        {key, Map.get(payload, key, :unknown)}
      end)

  defp delta(values, previous),
    do:
      Map.new(values, fn {key, value} ->
        {key,
         if(is_integer(value) and is_integer(previous[key]),
           do: max(0, value - previous[key]),
           else: :unknown
         )}
      end)

  defp charge(%{input_tokens: i, cached_tokens: c, output_tokens: o})
       when is_integer(i) and is_integer(c) and is_integer(o),
       do: max(0, i - c) + o

  defp charge(_), do: :unknown
  defp enforce_budget(%{status: :complete} = goal), do: goal

  defp enforce_budget(%{token_budget: budget, tokens_used: used} = goal)
       when is_integer(budget) and used >= budget,
       do: %{goal | status: :budget_limited}

  defp enforce_budget(goal), do: goal
  defp valid_objective?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_budget?(nil, _), do: true

  defp valid_budget?(value, max),
    do: is_integer(value) and value > 0 and (max == nil or value <= max)

  defp status(value) when is_binary(value),
    do: Enum.find(@statuses, &(Atom.to_string(&1) == value))

  defp status(value), do: value

  def normalize(attrs),
    do:
      Map.new(attrs, fn {key, value} ->
        {Enum.find([:objective, :status, :token_budget], key, &(Atom.to_string(&1) == key)),
         value}
      end)

  def digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()
  defp error(class, message), do: {:error, Error.new(class, message)}
end
