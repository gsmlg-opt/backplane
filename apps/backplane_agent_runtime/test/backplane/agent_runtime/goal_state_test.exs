defmodule Backplane.AgentRuntime.GoalStateTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.Goal.State

  defp goal(budget \\ nil) do
    {:ok, state} = State.new("thread", [])
    {:ok, state} = State.create(state, %{objective: "ship", token_budget: budget})
    state
  end

  defp receipt(state, id, type, payload, turn \\ "turn") do
    %{
      receipt_id: id,
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: turn,
      expected_goal_id: State.snapshot(state).goal.goal_id,
      type: type,
      payload: payload
    }
  end

  test "model status and completed-only replacement" do
    state = goal()
    assert {:error, %{class: :validation}} = State.update(state, :model, %{status: :active})
    {:ok, state} = State.update(state, :model, %{status: :blocked})
    assert {:error, %{class: :resource_conflict}} = State.create(state, %{objective: "replace"})
    {:ok, state} = State.update(state, :host, %{status: :active})
    {:ok, state} = State.update(state, :model, %{status: :complete})
    assert {:ok, _} = State.create(state, %{objective: "replace"})
  end

  test "charge excludes cache and reasoning; reports and receipts deduplicate" do
    state = goal(100)

    event =
      receipt(state, "usage", :usage, %{
        attempt_id: "a",
        identity: "u",
        input_tokens: 50,
        cached_tokens: 40,
        output_tokens: 7,
        reasoning_tokens: 5
      })

    {:ok, state} = State.account(state, event)
    {:ok, state} = State.account(state, event)
    {:ok, state} = State.account(state, %{event | receipt_id: "terminal-repeat"})
    assert %{goal: %{tokens_used: 17}, remaining_tokens: 83} = State.response(state)

    assert {:error, %{class: :resource_conflict}} =
             State.account(state, put_in(event.payload.output_tokens, 8))

    assert {:error, %{class: :resource_conflict}} =
             State.account(state, %{event | expected_goal_id: "old"})

    refute Map.has_key?(State.response(state).goal, :goal_id)
    refute Map.has_key?(State.response(state).goal, :revision)
  end

  test "unknown charge suspends budget admission without fabricating exhaustion" do
    state = goal(100)

    {:ok, state} =
      State.account(
        state,
        receipt(state, "u", :usage, %{attempt_id: "a", identity: "u", output_tokens: 7})
      )

    assert State.response(state).goal.status == :active
    assert State.snapshot(state).accounting_uncertain
    refute State.continuable?(state)
  end

  test "uncertain accounting exposes uncertainty and suppresses budget claims after completion" do
    state = goal(100)
    response = State.response(state)
    assert response.remaining_tokens == 100
    refute Map.has_key?(response, :accounting_uncertain)

    {:ok, state} =
      State.account(
        state,
        receipt(state, "known", :usage, %{
          attempt_id: "a",
          identity: "known",
          input_tokens: 12,
          cached_tokens: 2,
          output_tokens: 3
        })
      )

    {:ok, state} =
      State.account(
        state,
        receipt(state, "unknown", :usage, %{
          attempt_id: "b",
          identity: "unknown",
          output_tokens: 7
        })
      )

    assert %{
             goal: %{status: :active, tokens_used: 13},
             accounting_uncertain: true,
             remaining_tokens: nil,
             completion_budget_report: nil
           } = State.response(state)

    {:ok, state} = State.update(state, :model, %{status: :complete})

    assert %{
             goal: %{status: :complete, tokens_used: 13},
             accounting_uncertain: true,
             remaining_tokens: nil,
             completion_budget_report: nil
           } = State.response(state)
  end

  test "budget status wins over pause but complete preserves final usage" do
    state = goal(10)

    {:ok, state} =
      State.account(
        state,
        receipt(state, "u", :usage, %{
          identity: "u",
          attempt_id: "a",
          input_tokens: 10,
          cached_tokens: 0,
          output_tokens: 2
        })
      )

    {:ok, state} = State.update(state, :model, %{status: :paused})
    assert State.response(state).goal.status == :budget_limited
    {:ok, state} = State.update(state, :model, %{status: :complete})
    assert State.response(state).goal.tokens_used == 12
    assert is_binary(State.response(state).completion_budget_report)
  end

  test "plan mode excludes usage and cumulative snapshots debit only new usage" do
    state = goal(100)
    {:ok, state} = State.account(state, receipt(state, "start", :turn_started, %{mode: :plan}))

    {:ok, state} =
      State.account(
        state,
        receipt(state, "u1", :usage, %{
          identity: "u1",
          attempt_id: "a",
          input_tokens: 20,
          cached_tokens: 5,
          output_tokens: 4
        })
      )

    assert State.response(state).goal.tokens_used == 0

    {:ok, state} =
      State.account(state, receipt(state, "start2", :turn_started, %{mode: :execution}, "turn2"))

    {:ok, state} =
      State.account(
        state,
        receipt(
          state,
          "u2",
          :usage,
          %{
            identity: "u2",
            attempt_id: "b",
            cumulative: true,
            input_tokens: 20,
            cached_tokens: 5,
            output_tokens: 4
          },
          "turn2"
        )
      )

    {:ok, state} =
      State.account(
        state,
        receipt(
          state,
          "u3",
          :usage,
          %{
            identity: "u3",
            attempt_id: "b",
            cumulative: true,
            input_tokens: 20,
            cached_tokens: 5,
            output_tokens: 9
          },
          "turn2"
        )
      )

    assert State.response(state).goal.tokens_used == 24
  end

  test "three executed exec failures block while successful tools reset" do
    state =
      Enum.reduce(1..3, goal(), fn n, state ->
        turn = "turn-#{n}"

        {:ok, state} =
          State.account(state, receipt(state, "s#{n}", :turn_started, %{trigger: :goal}, turn))

        {:ok, state} =
          State.account(
            state,
            receipt(
              state,
              "t#{n}",
              :tool_finished,
              %{tool: "exec", success: false, handler_executed: true},
              turn
            )
          )

        {:ok, state} =
          State.account(
            state,
            receipt(state, "e#{n}", :turn_stopped, %{outcome: :complete}, turn)
          )

        state
      end)

    assert State.response(state).goal.status == :blocked
    {:ok, state} = State.update(state, :host, %{status: :active})
    assert State.snapshot(state).failure_turns == 0
  end

  test "empty automatic final turns block at three; interruption persists a deferral" do
    state =
      Enum.reduce(1..3, goal(), fn n, state ->
        turn = "turn-#{n}"

        {:ok, state} =
          State.account(state, receipt(state, "s#{n}", :turn_started, %{trigger: :goal}, turn))

        {:ok, state} =
          State.account(
            state,
            receipt(
              state,
              "i#{n}",
              :item_completed,
              %{kind: :assistant, text: "", phase: :final},
              turn
            )
          )

        {:ok, state} =
          State.account(
            state,
            receipt(state, "e#{n}", :turn_stopped, %{outcome: :complete}, turn)
          )

        state
      end)

    assert State.response(state).goal.status == :blocked
    state = goal()

    {:ok, state} =
      State.account(state, receipt(state, "abort", :turn_aborted, %{reason: :interrupt_turn}))

    assert State.snapshot(state).continuation_deferral.reason == :interrupt_turn
    refute State.continuable?(state)
  end

  test "retryable errors do not stop goals until retry is exhausted" do
    state = goal()

    {:ok, state} =
      State.account(
        state,
        receipt(state, "retry", :turn_error, %{
          class: :transient_transport,
          retryable: true,
          exhausted: false
        })
      )

    assert State.response(state).goal.status == :active

    {:ok, state} =
      State.account(
        state,
        receipt(state, "exhausted", :turn_error, %{
          class: :transient_transport,
          retryable: true,
          exhausted: true
        })
      )

    assert State.response(state).goal.status == :blocked
    state = goal()

    {:ok, state} =
      State.account(state, receipt(state, "quota", :turn_error, %{class: :usage_limit}))

    assert State.response(state).goal.status == :usage_limited
  end

  test "usage requires stable attempt and report identity and rejects invalid metrics" do
    state = goal()

    event =
      receipt(state, "usage", :usage, %{input_tokens: 8, cached_tokens: 0, output_tokens: 1})

    assert {:error, %{class: :validation}} = State.account(state, event)

    event = %{
      event
      | payload: %{
          identity: "u",
          attempt_id: "a",
          input_tokens: -1,
          cached_tokens: 0,
          output_tokens: 1
        }
    }

    assert {:error, %{class: :validation}} = State.account(state, event)
  end

  test "non-interruption aborts reset empty audit; interruption is evaluated at idle" do
    state = goal()
    {:ok, state} = State.account(state, receipt(state, "s1", :turn_started, %{trigger: :goal}))
    {:ok, state} = State.account(state, receipt(state, "a1", :turn_aborted, %{reason: :replaced}))
    assert State.snapshot(state).empty_turns == 0

    {:ok, state} =
      State.account(state, receipt(state, "s2", :turn_started, %{trigger: :goal}, "turn2"))

    {:ok, state} =
      State.account(
        state,
        receipt(state, "a2", :turn_aborted, %{reason: :interrupt_turn}, "turn2")
      )

    assert State.snapshot(state).empty_turns == 0
    {:ok, state} = State.evaluate_idle(state)
    assert State.snapshot(state).empty_turns == 1
    {:ok, state} = State.evaluate_idle(state)
    assert State.snapshot(state).empty_turns == 1
  end

  test "normalized completion report names emitted goal fields" do
    state = goal(10)
    {:ok, state} = State.update(state, :model, %{status: :complete})
    response = State.response(state)
    assert response.completion_budget_report =~ "goal.token_budget"
    assert response.completion_budget_report =~ "goal.tokens_used"
    assert response.completion_budget_report =~ "goal.time_used_seconds"
  end

  test "host resume discards pending interruption audit" do
    state = goal()
    {:ok, state} = State.account(state, receipt(state, "s", :turn_started, %{trigger: :goal}))

    {:ok, state} =
      State.account(state, receipt(state, "a", :turn_aborted, %{reason: :interrupt_turn}))

    {:ok, state} = State.update(state, :host, %{status: :active})
    {:ok, state} = State.evaluate_idle(state)
    assert State.snapshot(state).empty_turns == 0
    assert State.snapshot(state).interrupted_turn == nil
  end

  test "late turn errors cannot reopen or change a completed goal" do
    state = goal()
    {:ok, state} = State.update(state, :model, %{status: :complete})

    {:ok, state} =
      State.account(state, receipt(state, "late-error", :turn_error, %{class: :usage_limit}))

    assert State.response(state).goal.status == :complete
  end

  test "unknown cumulative metrics never advance the last known charge baseline" do
    state = goal(100)

    first =
      receipt(state, "partial", :usage, %{
        identity: "partial",
        attempt_id: "a",
        cumulative: true,
        input_tokens: 50,
        cached_tokens: :unknown,
        output_tokens: 2
      })

    {:ok, state} = State.account(state, first)

    known =
      receipt(state, "known", :usage, %{
        identity: "known",
        attempt_id: "a",
        cumulative: true,
        input_tokens: 60,
        cached_tokens: 40,
        output_tokens: 7
      })

    {:ok, state} = State.account(state, known)
    assert State.response(state).goal.tokens_used == 27
    assert State.snapshot(state).accounting_uncertain
  end

  test "internal Usage ledger normalizes cumulative reports including partial metrics" do
    state = goal(100)

    first =
      receipt(state, "partial-ledger", :usage, %{
        identity: "partial-ledger",
        attempt_id: "a",
        cumulative: true,
        input_tokens: 50,
        cached_tokens: :unknown,
        output_tokens: 2
      })

    {:ok, state} = State.account(state, first)

    known =
      receipt(state, "known-ledger", :usage, %{
        identity: "known-ledger",
        attempt_id: "a",
        cumulative: true,
        input_tokens: 60,
        cached_tokens: 40,
        output_tokens: 7
      })

    {:ok, state} = State.account(state, known)

    assert Backplane.AgentRuntime.Usage.totals(State.snapshot(state).usage) == %{
             input_tokens: 60,
             cached_tokens: 40,
             output_tokens: 7,
             reasoning_tokens: 0
           }

    assert State.response(state).goal.tokens_used == 27

    duplicate_identity = %{
      known
      | receipt_id: "changed-ledger",
        payload: %{known.payload | input_tokens: 70}
    }

    assert {:error, %{class: :resource_conflict}} = State.account(state, duplicate_identity)
  end
end
