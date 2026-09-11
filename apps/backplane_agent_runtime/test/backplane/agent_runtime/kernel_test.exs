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

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 1},
          {:tool_invoked, 12, tool_invocation()}
        )

      assert run.state == :running

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 2},
          {:tool_completed, 13, %{invocation_id: "tool_1", result: %{"text" => "ok"}}}
        )

      assert run.state == :running

      {:ok, run, transition, []} =
        Kernel.execute(
          %{run | expected_revision: 3},
          {:provider_completed, 14,
           %{
             step_id: "step_1",
             attempt_id: "attempt_1",
             outcome: %{"text" => "done"}
           }}
        )

      assert run.state == :completed
      assert run.outcome == %{"text" => "done"}
      assert transition.expected_revision == 4
      assert transition.state == :completed

      assert [%{type: "run.completed"}] = transition.events
    end

    test "waits for another run and settles through a typed continuation" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 1},
          {:wait_started, 12, %{target_run_id: "run_child"}}
        )

      assert run.state == :waiting_result

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 2},
          {:wait_resolved, 13,
           %{
             target_run_id: "run_child",
             result: %{"text" => "child settled"}
           }}
        )

      assert run.state == :completed

      assert run.outcome == %{
               "target_run_id" => "run_child",
               "result" => %{"text" => "child settled"}
             }
    end

    test "rejects invalid, duplicate, late, and terminal inputs" do
      run = base_run()
      assert {:error, %Backplane.AgentRuntime.Error{}} = Kernel.execute(run, {:start, 10})

      {:ok, run, _, []} = Kernel.execute(run, {:admit, 10, %{state: :running}})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(%{run | expected_revision: 1}, {:admit, 11, %{}})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(%{run | expected_revision: 1}, {:provider_completed, 12, %{}})

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 1},
          {:provider_completed, 12,
           %{step_id: "step_1", attempt_id: "attempt_1", outcome: %{"text" => "done"}}}
        )

      assert Kernel.terminal?(:completed)

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(%{run | expected_revision: 2}, {:cancel, 13})
    end

    test "cancellation is not cleanup completion and deadline has terminal precedence" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, transition, []} =
        Kernel.execute(%{run | expected_revision: 1}, {:cancel, 11})

      assert run.state == :cancelling
      assert [%{type: "run.cancelling"}] = transition.events

      {:ok, run, _, []} =
        Kernel.execute(%{run | expected_revision: 2}, {:deadline_exceeded, 12})

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
          %{run | expected_revision: 1},
          {:provider_started, 11,
           %{
             step_id: "step_1",
             attempt_id: "attempt_1"
           }}
        )

      assert result ==
               Kernel.execute(
                 %{run | expected_revision: 1},
                 {:provider_started, 11,
                  %{
                    step_id: "step_1",
                    attempt_id: "attempt_1"
                  }}
               )

      assert {:ok, _, _, []} = result
      assert elem(result, 1).state == :running
    end

    test "terminal precedence cannot be reopened by stale external results" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, _, []} =
        Kernel.execute(
          %{run | expected_revision: 1},
          {:provider_completed, 11, %{step_id: "step_1", attempt_id: "attempt_1", outcome: %{}}}
        )

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(
                 %{run | expected_revision: 2},
                 {:tool_completed, 12, %{invocation_id: "tool_1", result: %{}}}
               )
    end

    test "cancellation can still be fenced to an explicit terminal" do
      {:ok, run, _, []} = Kernel.execute(base_run(), {:admit, 10, %{state: :running}})

      {:ok, run, _, []} = Kernel.execute(%{run | expected_revision: 1}, {:cancel, 11})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Kernel.execute(
                 %{run | expected_revision: 2},
                 {:provider_completed, 12,
                  %{step_id: "step_1", attempt_id: "attempt_1", outcome: %{}}}
               )
    end
  end

  defp base_run do
    %{
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
      tool_name: "example",
      tool_revision: 1,
      arguments: %{},
      state: :admitted,
      result: nil
    }
  end
end
