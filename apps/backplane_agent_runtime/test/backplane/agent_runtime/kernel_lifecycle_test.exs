defmodule Backplane.AgentRuntime.KernelLifecycleTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Kernel

  test "default admission remains queued until start" do
    assert {:ok, admitted, transition, []} = Kernel.execute(base_run(), {:admit, 10, %{}})
    assert admitted.state == :queued
    assert admitted.admitted == true
    assert transition.state == :queued

    assert {:ok, running, transition, []} = Kernel.execute(admitted, {:start, 11})
    assert running.state == :running
    assert transition.state == :running
  end

  test "terminal admission is rejected while running admission remains compatible" do
    assert {:ok, %{state: :running}, _, []} =
             Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

    assert {:error, %Error{class: :validation}} =
             Kernel.execute(base_run(), {:admit, 10, %{state: :completed}})
  end

  test "a dependency result resumes its exact continuation" do
    run = admitted_run()

    assert {:ok, waiting, _, []} =
             Kernel.execute(run, {:wait_started, 11, wait_identity("continuation_1")})

    resolution =
      wait_identity("continuation_1")
      |> Map.put(:result, %{"text" => "child settled"})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(
               waiting,
               {:wait_resolved, 12, resolution |> Map.put(:continuation_id, "stale_continuation")}
             )

    assert waiting.state == :waiting_result
    assert waiting.context == %{"messages" => []}

    assert {:ok, resumed, transition, []} =
             Kernel.execute(waiting, {:wait_resolved, 13, resolution})

    assert resumed.state == :running
    assert resumed.outcome == nil
    assert resumed.active_wait == nil
    assert resumed.continuation_results["continuation_1"] == resolution.result
    assert transition.state == :running
  end

  test "provider tool continuation reaches one final terminal" do
    provider = provider_identity("step_1", "attempt_1")
    {:ok, run, _, []} = Kernel.execute(admitted_run(), {:provider_started, 11, provider})

    {:ok, run, transition, []} =
      Kernel.execute(
        run,
        {:provider_completed, 12,
         provider
         |> Map.put(:final?, false)
         |> Map.put(:result, %{"tool_call" => "tool_1"})
         |> Map.put(:context, %{"messages" => ["call tool"]})}
      )

    assert run.state == :running
    assert run.context == %{"messages" => ["call tool"]}
    assert transition.state == :running

    invocation = tool_invocation(provider, "tool_1")
    {:ok, run, _, []} = Kernel.execute(run, {:tool_invoked, 13, invocation})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(
               run,
               {:provider_started, 14, provider_identity("step_2", "attempt_2")}
             )

    completion =
      invocation
      |> identity_fields()
      |> Map.put(:result, %{"text" => "ok"})

    {:ok, run, _, []} = Kernel.execute(run, {:tool_completed, 15, completion})

    continuation = provider_identity("step_2", "attempt_2")
    {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 16, continuation})

    assert {:ok, completed, transition, []} =
             Kernel.execute(
               run,
               {:provider_completed, 17,
                continuation
                |> Map.put(:final?, true)
                |> Map.put(:outcome, %{"text" => "done"})}
             )

    assert completed.state == :completed
    assert completed.outcome == %{"text" => "done"}
    assert transition.state == :completed

    assert {:error, %Error{class: :validation}} =
             Kernel.execute(
               completed,
               {:provider_completed, 18, Map.put(continuation, :final?, true)}
             )
  end

  test "a stale attempt is rejected while a newer attempt is running" do
    old = provider_identity("step_1", "attempt_1")
    current = provider_identity("step_1", "attempt_2")
    {:ok, run, _, []} = Kernel.execute(admitted_run(), {:provider_started, 11, old})
    {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 12, current})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(run, {:provider_completed, 13, Map.put(old, :final?, false)})

    assert run.active_provider.attempt_id == "attempt_2"
    assert run.context == %{"messages" => []}
  end

  test "wrong tool invocation and duplicate completion cannot change context" do
    provider = provider_identity("step_1", "attempt_1")
    {:ok, run, _, []} = Kernel.execute(admitted_run(), {:provider_started, 11, provider})

    {:ok, run, _, []} =
      Kernel.execute(
        run,
        {:provider_completed, 12, provider |> Map.put(:final?, false) |> Map.put(:result, %{})}
      )

    invocation = tool_invocation(provider, "tool_1")
    {:ok, run, _, []} = Kernel.execute(run, {:tool_invoked, 13, invocation})

    wrong =
      invocation
      |> identity_fields()
      |> Map.put(:invocation_id, "tool_wrong")
      |> Map.put(:result, %{"bad" => true})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(run, {:tool_completed, 14, wrong})

    completion = invocation |> identity_fields() |> Map.put(:result, %{"ok" => true})
    {:ok, settled, _, []} = Kernel.execute(run, {:tool_completed, 15, completion})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(settled, {:tool_completed, 16, completion})

    assert settled.context == run.context
    assert settled.tool_results["tool_1"] == %{"ok" => true}
  end

  test "old incarnation results are fenced" do
    provider = provider_identity("step_1", "attempt_1")
    {:ok, run, _, []} = Kernel.execute(admitted_run(), {:provider_started, 11, provider})
    stale = provider |> Map.put(:incarnation, 0) |> Map.put(:final?, true)

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(run, {:provider_completed, 12, stale})

    assert run.state == :running
    assert run.outcome == nil
  end

  test "final completion is blocked while required owned work is unsettled" do
    provider = provider_identity("step_1", "attempt_1")
    run = %{admitted_run() | children: ["owned_child"]}
    {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 11, provider})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(
               run,
               {:provider_completed, 12,
                provider |> Map.put(:final?, true) |> Map.put(:outcome, %{})}
             )

    assert run.state == :running
    assert run.outcome == nil

    assert {:ok, run, _, []} =
             Kernel.execute(
               run,
               {:child_settled, 13,
                %{
                  run_id: "run_1",
                  incarnation: 1,
                  child_run_id: "owned_child",
                  result: %{"state" => "completed"}
                }}
             )

    assert {:ok, completed, _, []} =
             Kernel.execute(
               run,
               {:provider_completed, 14,
                provider |> Map.put(:final?, true) |> Map.put(:outcome, %{"done" => true})}
             )

    assert completed.state == :completed
    assert completed.child_results["owned_child"] == %{"state" => "completed"}
  end

  test "cancellation reaches confirmed cancelled or retained uncertainty through cleanup" do
    {:ok, cancelling, transition, []} = Kernel.execute(admitted_run(), {:cancel, 11})
    assert cancelling.state == :cancelling
    assert cancelling.stop_reason == :cancelled
    assert transition.state == :cancelling

    assert {:ok, cancelled, _, []} =
             Kernel.execute(
               cancelling,
               {:cleanup_settled, 12,
                %{certainty: :confirmed, settled: Kernel.cleanup_requirements(cancelling)}}
             )

    assert cancelled.state == :cancelled
    assert cancelled.outcome["stop_reason"] == "cancelled"

    {:ok, cancelling, _, []} = Kernel.execute(admitted_run(), {:cancel, 20})

    assert {:ok, uncertain, _, []} =
             Kernel.execute(
               cancelling,
               {:cleanup_settled, 21,
                %{certainty: :uncertain, evidence: %{"invocation_id" => "tool_1"}}}
             )

    assert uncertain.state == :unknown_outcome
    assert uncertain.outcome["cleanup"]["evidence"] == %{"invocation_id" => "tool_1"}
  end

  test "deadline waits for cleanup and completion racing cancellation is rejected" do
    provider = provider_identity("step_1", "attempt_1")
    {:ok, run, _, []} = Kernel.execute(admitted_run(), {:provider_started, 11, provider})
    {:ok, cancelling, _, []} = Kernel.execute(run, {:deadline_exceeded, 12})

    assert cancelling.state == :cancelling
    assert cancelling.stop_reason == :deadline_exceeded

    assert {:error, %Error{class: :validation}} =
             Kernel.execute(
               cancelling,
               {:provider_completed, 13,
                provider |> Map.put(:final?, true) |> Map.put(:outcome, %{})}
             )

    assert {:ok, timed_out, _, []} =
             Kernel.execute(
               cancelling,
               {:cleanup_settled, 14,
                %{certainty: :confirmed, settled: Kernel.cleanup_requirements(cancelling)}}
             )

    assert timed_out.state == :timed_out
  end

  test "deterministic replay produces identical state and transitions" do
    command = {:provider_started, 11, provider_identity("step_1", "attempt_1")}
    assert Kernel.execute(admitted_run(), command) == Kernel.execute(admitted_run(), command)
  end

  defp admitted_run do
    {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})
    run
  end

  defp base_run do
    %{
      run_id: "run_1",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      context: %{"messages" => []},
      children: []
    }
  end

  defp provider_identity(step_id, attempt_id) do
    %{run_id: "run_1", incarnation: 1, step_id: step_id, attempt_id: attempt_id}
  end

  defp tool_invocation(provider, invocation_id) do
    Map.merge(provider, %{
      invocation_id: invocation_id,
      tool_name: "example",
      tool_revision: 1,
      arguments: %{},
      state: :admitted,
      result: nil
    })
  end

  defp identity_fields(invocation) do
    Map.take(invocation, [:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
  end

  defp wait_identity(continuation_id) do
    %{
      run_id: "run_1",
      incarnation: 1,
      continuation_id: continuation_id,
      target_run_id: "run_child"
    }
  end
end
