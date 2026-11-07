defmodule Backplane.AgentRuntime.ProviderSelectionTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{Kernel, ProviderSelection}

  test "initial bindings cannot persist credentials or unrecognized metadata" do
    binding = %{provider: "a", model: "a", provider_context: %{credential: "private"}}
    assert {:error, _} = ProviderSelection.validate_initial(binding)
    assert ProviderSelection.initial(binding, true).binding == %{provider: "a", model: "a"}

    assert {:error, _} =
             Backplane.AgentRuntime.Conversation.start_link(provider_selection: binding)
  end

  test "Kernel pins adoption to the opened failed attempt and leaves a superseding generation pending" do
    {run, failed} = failed_run()
    run = execute(run, :provider_selection_staged, %{request: request("B")})

    run =
      execute(run, :provider_recovery_opened, %{
        boundary_id: "boundary",
        failed_attempt: failed,
        turn_id: "turn"
      })

    boundary = ProviderSelection.state(run).boundary
    run = execute(run, :provider_selection_staged, %{request: request("C")})

    {:ok, adoption, view, _} =
      ProviderSelection.prepare_result({:ok, %{provider: "b", model: "b"}}, boundary, [])

    next_attempt = %{
      step_id: "next-step",
      attempt_id: "next-attempt",
      turn_id: "turn",
      provider_adoption: adoption,
      provider_view: view
    }

    assert {:error, _} =
             Kernel.execute(
               run,
               {:provider_started, 100,
                Map.merge(identity(), %{
                  next_attempt
                  | provider_adoption: %{adoption | request_id: "C"}
                })}
             )

    next = execute(run, :provider_started, next_attempt)
    assert next.provider_selection_state.pending.request.request_id == "C"
    assert next.provider_selection_state.binding.request_id == "B"
    assert next.provider_attempts["next-attempt"].provider_selection.request_id == "B"
    assert next.provider_selection_state.boundary == nil
  end

  test "Execution derives committed provider selection and view from the validated native transition" do
    alias Backplane.AgentRuntime.{Budget, EphemeralStore, Execution}
    {run, failed} = failed_run()
    run = execute(run, :provider_selection_staged, %{request: request("B")})

    run =
      execute(run, :provider_recovery_opened, %{
        boundary_id: "b",
        failed_attempt: failed,
        turn_id: "turn"
      })

    boundary = ProviderSelection.state(run).boundary
    prepared_messages = [%{role: :user, content: "native view"}]

    {:ok, adoption, view, _} =
      ProviderSelection.prepare_result(
        {:ok, %{provider: "b", model: "b", messages: prepared_messages}},
        boundary,
        []
      )

    {:ok, budget} = Budget.new(%{work: 5})
    run = Map.put(run, :execution_budget, budget)
    {:ok, table} = EphemeralStore.new(1)
    :ets.insert(table, {run.run_id, %{run: run, revision: run.expected_revision, effects: []}})

    input =
      Map.merge(identity(), %{
        step_id: "next",
        attempt_id: "next",
        turn_id: "turn",
        provider_adoption: adoption,
        provider_view: view
      })

    meta = %{
      command: {:provider_started, 100, input},
      operation: %{
        provider_selection: %{provider: "forged", model: "C"},
        messages: [%{role: :user, content: "forged view"}]
      }
    }

    assert {:ok, receipt, prepared} =
             Execution.commit(EphemeralStore, table, run, meta, adapter: __MODULE__)

    assert prepared.operation.provider_selection.request_id == "B"
    assert prepared.operation.provider_selection.provider == "b"
    assert prepared.operation.messages == prepared_messages
    assert hd(receipt.outbox).operation == prepared.operation
    assert prepared.run.provider_selection_state.binding == prepared.operation.provider_selection

    assert prepared.run.provider_attempts["next"].provider_selection ==
             prepared.operation.provider_selection
  end

  test "Kernel rejects forged failed-attempt identity and replay after publication" do
    {run, failed} = failed_run()
    run = execute(run, :provider_selection_staged, %{request: request("B")})

    for forged <- [
          %{failed | incarnation: 22},
          %{failed | run_id: "other"},
          %{failed | attempt_id: "other"}
        ] do
      assert {:error, _} =
               Kernel.execute(
                 run,
                 {:provider_recovery_opened, 100,
                  Map.merge(identity(), %{
                    boundary_id: "b",
                    failed_attempt: forged,
                    turn_id: "turn"
                  })}
               )
    end

    run = put_in(run, [:provider_attempts, failed.attempt_id, :replay_blocked], true)

    assert {:error, _} =
             Kernel.execute(
               run,
               {:provider_recovery_opened, 100,
                Map.merge(identity(), %{boundary_id: "b", failed_attempt: failed, turn_id: "turn"})}
             )
  end

  test "only the active native provider can commit a publication marker and attempts cannot overlap" do
    run = running()
    attempt = Map.merge(identity(), %{step_id: "step", attempt_id: "attempt", turn_id: "turn"})
    run = execute(run, :provider_started, attempt)

    assert {:error, _} =
             Kernel.execute(
               run,
               {:provider_replay_blocked, 100, %{attempt | attempt_id: "wrong"}}
             )

    assert {:error, _} =
             Kernel.execute(
               run,
               {:provider_started, 100, %{attempt | step_id: "next", attempt_id: "next"}}
             )

    marked = execute(run, :provider_replay_blocked, Map.drop(attempt, [:turn_id]))
    assert ProviderSelection.blocked?(marked, "attempt")
  end

  test "request receipts are bounded and exact retries cannot overwrite later intent" do
    run =
      Enum.reduce(1..64, running(), fn n, run ->
        execute(run, :provider_selection_staged, %{request: request("#{n}")})
      end)

    assert {:error, _} =
             Kernel.execute(
               run,
               {:provider_selection_staged, 100, Map.merge(identity(), %{request: request("65")})}
             )

    repeat = execute(run, :provider_selection_staged, %{request: request("1")})
    assert repeat.provider_selection_state.pending.request.request_id == "64"
    assert ProviderSelection.receipt(repeat, "1") == ProviderSelection.receipt(run, "1")

    assert {:error, _} =
             ProviderSelection.stage(run, %{request: Map.put(request("65"), :extra, self())})

    assert {:error, _} = ProviderSelection.stage(run, %{request: %{request("65") | turn_id: nil}})
  end

  test "provider views require a matching canonical prefix and explicit context reset clears them" do
    {run, failed} = failed_run()
    run = execute(run, :provider_selection_staged, %{request: request("B")})

    run =
      execute(run, :provider_recovery_opened, %{
        boundary_id: "b",
        failed_attempt: failed,
        turn_id: "turn"
      })

    boundary = ProviderSelection.state(run).boundary

    messages = [
      %{role: :user, content: "summary"},
      %{role: :tool, tool_call_id: "settled", result: %{text: "retained tool result"}}
    ]

    {:ok, adoption, view, _} =
      ProviderSelection.prepare_result(
        {:ok, %{provider: "b", model: "b", messages: messages}},
        boundary,
        []
      )

    run =
      execute(run, :provider_started, %{
        step_id: "next",
        attempt_id: "next",
        turn_id: "turn",
        provider_adoption: adoption,
        provider_view: view
      })

    assert {:ok, ^messages} = ProviderSelection.messages(run, [])
    assert {:ok, projected} = ProviderSelection.messages(run, [%{role: :user, content: "suffix"}])
    assert projected == messages ++ [%{role: :user, content: "suffix"}]
    reset = ProviderSelection.clear_view_on_context_reset(run, %{context_window: 2})
    assert reset.provider_selection_state.view == nil
  end

  defp failed_run do
    run = running()
    attempt = Map.merge(identity(), %{step_id: "step", attempt_id: "attempt", turn_id: "turn"})
    run = execute(run, :provider_started, attempt)
    failed = Map.drop(attempt, [:turn_id])

    run =
      execute(
        run,
        :provider_completed,
        Map.merge(failed, %{final?: false, result: %{error: "context", recovery: :retry}})
      )

    {run, failed}
  end

  defp running do
    %{
      run_id: "run",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      context: %{conversation: %{turn_id: "turn", messages: []}},
      active_provider: nil,
      provider_selection_state: ProviderSelection.initial(%{provider: "a", model: "a"}, true),
      active_tools: %{},
      active_wait: nil,
      children: [],
      settled_children: [],
      dependencies: []
    }
  end

  defp identity, do: %{run_id: "run", incarnation: 1}

  defp request(id),
    do:
      Map.merge(identity(), %{
        turn_id: "turn",
        request_id: id,
        mode: :select,
        intent: %{model: id}
      })

  defp execute(run, command, input) do
    {:ok, next, _, []} = Kernel.execute(run, {command, 100, Map.merge(identity(), input)})
    next
  end
end
