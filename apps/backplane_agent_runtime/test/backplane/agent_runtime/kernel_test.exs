defmodule Backplane.AgentRuntime.KernelTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Kernel

  describe "deterministic run state machine" do
    test "completes the scripted run without I/O" do
      {:ok, run, transition, []} =
        Kernel.execute(
          base_run(),
          {:admit, 10, %{state: :running, input: %{"message" => "hi"}, deadline: 100}}
        )

      assert run.state == :running
      assert run.deadline == 100
      assert transition.expected_revision == 1
      assert [%{type: "run.admitted"}] = transition.events

      provider = provider_identity("step_1", "attempt_1")

      {:ok, run, _, []} =
        Kernel.execute(run, {:provider_started, 11, provider})

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:provider_completed, 12, provider |> Map.put(:final?, false) |> Map.put(:result, %{})}
        )

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:tool_invoked, 13, tool_invocation()}
        )

      assert run.state == :running

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:tool_completed, 14,
           tool_invocation()
           |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
           |> Map.put(:result, %{"text" => "ok"})}
        )

      assert run.state == :running

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:provider_started, 15, provider_identity("step_2", "attempt_2")}
        )

      {:ok, run, transition, []} =
        Kernel.execute(
          run,
          {:provider_completed, 16,
           provider_identity("step_2", "attempt_2")
           |> Map.put(:final?, true)
           |> Map.put(:outcome, %{"text" => "done"})}
        )

      assert run.state == :completed
      assert run.outcome == %{"text" => "done"}
      assert transition.expected_revision == 7
      assert transition.state == :completed

      assert [%{type: "run.completed"}] = transition.events
    end

    test "waits for another run and settles through a typed continuation" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:wait_started, 12, wait_identity()}
        )

      assert run.state == :waiting_result

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:wait_resolved, 13, Map.put(wait_identity(), :result, %{"text" => "child settled"})}
        )

      assert run.state == :running
      assert run.outcome == nil
      assert run.continuation_results["continuation_1"] == %{"text" => "child settled"}
    end

    test "rejects invalid, duplicate, late, and terminal inputs" do
      run = base_run()
      assert {:error, %Backplane.AgentRuntime.Error{}} = Kernel.execute(run, {:start, 10})

      {:ok, run, _, []} = Kernel.execute(run, {:admit, 10, %{state: :running}})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(%{run | expected_revision: 1}, {:admit, 11, %{}})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(%{run | expected_revision: 1}, {:provider_completed, 12, %{}})

      provider = provider_identity("step_1", "attempt_1")
      {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 12, provider})

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:provider_completed, 13,
           provider |> Map.put(:final?, true) |> Map.put(:outcome, %{"text" => "done"})}
        )

      assert Kernel.terminal?(:completed)

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(run, {:cancel, 14})
    end

    test "deadline is terminal only after confirmed cleanup" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, transition, []} =
        Kernel.execute(run, {:deadline_exceeded, 11})

      assert run.state == :cancelling
      assert [%{type: "run.cancelling"}] = transition.events

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:cleanup_settled, 12,
           %{certainty: :confirmed, settled: Kernel.cleanup_requirements(run)}}
        )

      assert run.state == :timed_out
      assert Kernel.terminal?(:timed_out)
    end

    test "deterministic replay produces the same state and transitions without effects" do
      run =
        base_run()
        |> Kernel.execute({:admit, 10, %{state: :running}})
        |> elem(1)

      result =
        Kernel.execute(
          run,
          {:provider_started, 11, provider_identity("step_1", "attempt_1")}
        )

      assert result ==
               Kernel.execute(
                 run,
                 {:provider_started, 11, provider_identity("step_1", "attempt_1")}
               )

      assert {:ok, _, _, []} = result
      assert elem(result, 1).state == :running
    end

    test "terminal precedence cannot be reopened by stale external results" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})
      provider = provider_identity("step_1", "attempt_1")
      {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 11, provider})

      {:ok, run, _, []} =
        Kernel.execute(
          run,
          {:provider_completed, 12, provider |> Map.put(:final?, true) |> Map.put(:outcome, %{})}
        )

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(
                 run,
                 {:tool_completed, 13,
                  tool_invocation()
                  |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
                  |> Map.put(:result, %{})}
               )
    end

    test "cancellation can still be fenced to an explicit terminal" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})
      provider = provider_identity("step_1", "attempt_1")
      {:ok, run, _, []} = Kernel.execute(run, {:provider_started, 11, provider})

      {:ok, run, _, []} = Kernel.execute(run, {:cancel, 12})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(
                 run,
                 {:provider_completed, 13,
                  provider |> Map.put(:final?, true) |> Map.put(:outcome, %{})}
               )
    end
  end

  defp base_run do
    %{
      run_id: "run_1",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end

  defp tool_invocation do
    %{
      invocation_id: "tool_1",
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1",
      tool_name: "example",
      tool_revision: 1,
      arguments: %{},
      state: :admitted,
      result: nil
    }
  end

  defp provider_identity(step_id, attempt_id) do
    %{run_id: "run_1", incarnation: 1, step_id: step_id, attempt_id: attempt_id}
  end

  defp wait_identity do
    %{
      run_id: "run_1",
      incarnation: 1,
      continuation_id: "continuation_1",
      target_run_id: "run_child"
    }
  end
end
