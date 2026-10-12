defmodule Backplane.AgentRuntime.GoalBridge do
  @moduledoc false
  alias Backplane.AgentRuntime.{Error, Goal, Usage}
  @metrics [:input_tokens, :cached_tokens, :output_tokens, :reasoning_tokens, :occupancy_tokens]

  # Normalized provider usage is cumulative within one attempt. Persist one
  # authoritative delta for that attempt, including terminal snapshot repeats.
  def report(ledger, snapshots, identity) do
    empty = Map.new(@metrics, &{&1, :unknown})

    with {:ok, metrics} <- Enum.reduce_while(snapshots, {:ok, empty}, &snapshot/2) do
      report =
        metrics
        |> Map.merge(Map.take(identity, [:run_id, :incarnation, :attempt_id, :step_id]))
        |> Map.put(:identity, "#{identity.run_id}:#{identity.incarnation}:#{identity.attempt_id}")

      with {:ok, next, _receipt} <- Usage.report(ledger, report), do: {:ok, next, report}
    end
  end

  def validate_options(opts) do
    case {Keyword.get(opts, :goal), Keyword.get(opts, :goal_binding)} do
      {nil, nil} ->
        :ok

      {goal, binding} when is_pid(goal) and is_map(binding) ->
        with true <-
               binding[:run_id] == Keyword.get(opts, :run_id) and
                 binding[:incarnation] == Keyword.get(opts, :incarnation, 1) and
                 binding[:thread_id] == Keyword.get(opts, :thread_id),
             {:ok, _} <- Goal.attribution(goal, binding) do
          :ok
        else
          false -> {:error, Error.new(:forbidden, "conversation goal binding identity differs")}
          {:error, _} = error -> error
        end

      _ ->
        {:error, Error.new(:validation, "goal requires a host-issued binding and thread_id")}
    end
  end

  def queue(s, conversation, events) do
    events = attributed_events(s.goal_binding, events)

    case s.goal_binding do
      %{expected_goal_id: goal_id} = binding when not is_nil(goal_id) ->
        revision = s.run.expected_revision + 1

        receipts =
          Enum.with_index(events, fn {type, payload}, index ->
            %{
              receipt_id: "#{s.run.run_id}:#{s.run.incarnation}:#{revision}:#{type}:#{index}",
              revision: revision,
              thread_id: binding.thread_id,
              run_id: s.run.run_id,
              incarnation: s.run.incarnation,
              turn_id: conversation.turn_id,
              expected_goal_id: goal_id,
              type: type,
              payload: payload
            }
          end)

        Map.update(conversation, :goal_outbox, receipts, &(&1 ++ receipts))

      _ ->
        conversation
    end
  end

  # The host can redeliver these committed receipts after Goal/store restart.
  # Clearing the run outbox is a separate acknowledged journal checkpoint.
  def redeliver(goal, binding, run) do
    receipts = get_in(run, [:context, :conversation, :goal_outbox]) || []
    deliver(goal, binding, receipts)
  end

  def deliver(goal, binding, receipts) do
    # Descendants contribute token usage in Codex's TokenUsageContributor;
    # their errors, stops and empty-turn audit belong to their own thread.
    # Filter saved child outboxes too, so recovery preserves that boundary.
    receipts =
      if descendant?(binding), do: Enum.filter(receipts, &(&1.type == :usage)), else: receipts

    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, responses} ->
      case Goal.committed(goal, Map.put(receipt, :binding, binding)) do
        {:ok, response} -> {:cont, {:ok, responses ++ [response]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp attributed_events(binding, events) do
    if descendant?(binding), do: Enum.filter(events, &(elem(&1, 0) == :usage)), else: events
  end

  defp descendant?(%{root_thread_id: root, root_goal_id: goal_id, thread_id: thread}),
    do: root != thread and not is_nil(goal_id)

  defp descendant?(_), do: false

  defp snapshot(value, {:ok, previous}) when is_map(value) do
    Enum.reduce_while(@metrics, {:ok, previous}, fn metric, {:ok, next} ->
      value = Map.get(value, metric, :unknown)
      old = Map.fetch!(previous, metric)

      cond do
        value in [nil, :unknown] -> {:cont, {:ok, next}}
        not is_integer(value) or value < 0 -> {:halt, invalid()}
        is_integer(old) and value < old -> {:halt, invalid()}
        true -> {:cont, {:ok, Map.put(next, metric, value)}}
      end
    end)
    |> case do
      {:ok, next} -> {:cont, {:ok, next}}
      error -> {:halt, error}
    end
  end

  defp snapshot(_, _), do: {:halt, invalid()}
  defp invalid, do: {:error, Error.new(:validation, "invalid cumulative provider usage")}
end
