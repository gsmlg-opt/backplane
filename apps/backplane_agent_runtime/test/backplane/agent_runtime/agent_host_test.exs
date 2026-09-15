defmodule Backplane.AgentRuntime.AgentHostTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.AgentHost
  alias Backplane.AgentRuntime.Error

  describe "agent identities" do
    test "supports hosted and owner-bound lifecycles without requiring processes" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 3, max_active_runs: 2})

      assert {:ok, _host, %{agent_id: "agent_a", lifecycle: :hosted}} =
               AgentHost.register(host, %{agent_id: "agent_a", lifecycle: :hosted, owner: nil})

      assert {:ok, _host, %{agent_id: "agent_b", lifecycle: :owner_bound, owner: "run_1"}} =
               AgentHost.register(host, %{
                 agent_id: "agent_b",
                 lifecycle: :owner_bound,
                 owner: "run_1"
               })
    end

    test "rejects invalid owner and duplicate lifecycle changes" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 2})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: "run_1"})

      {:ok, host, receipt} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      assert receipt.agent_id == "agent"

      assert {:ok, _host, ^receipt} =
               AgentHost.register(host, %{
                 agent_id: "agent",
                 lifecycle: :owner_bound,
                 owner: "run_1"
               })
    end
  end

  describe "bounded work admission" do
    test "records accepted runs and enforces quota" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      assert {:ok, host, %{status: :accepted, active_runs: 1, run_id: "run-fixed"}} =
               AgentHost.submit(host, "agent", %{run_id: "run-fixed"})

      assert host.runs["run-fixed"] == %{
               run_id: "run-fixed",
               agent_id: "agent",
               status: :accepted
             }

      assert {:ok, ^host, %{status: :accepted, active_runs: 1, run_id: "run-fixed"}} =
               AgentHost.submit(host, "agent", %{run_id: "run-fixed"})

      assert {:error, %Error{class: :overloaded}} = AgentHost.submit(host, "agent")
    end

    test "terminal settlement releases capacity exactly once" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 1, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      assert {:ok, host, %{run_id: "run_1", status: :accepted}} =
               AgentHost.submit(host, "agent", %{run_id: "run_1"})

      assert {:ok, host, %{run_id: "run_1", status: :completed, settled?: true}} =
               AgentHost.settle(host, "run_1", :completed)

      assert host.agents["agent"].active_runs == 0

      assert {:ok, same_host, %{status: :completed, settled?: false}} =
               AgentHost.settle(host, "run_1", :completed)

      assert same_host == host

      assert {:error, %Error{class: :resource_conflict}} =
               AgentHost.settle(host, "run_1", :failed)

      assert {:ok, next_host, %{status: :accepted, run_id: next_run_id}} =
               AgentHost.submit(host, "agent")

      assert next_run_id == "runtime_1:run:1"
      assert next_host.agents["agent"].active_runs == 1
    end

    test "timed-out settlement releases capacity exactly once" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 1, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      {:ok, host, _} = AgentHost.submit(host, "agent", %{run_id: "timed-run"})

      assert {:ok, host, %{status: :timed_out, settled?: true, active_runs: 0}} =
               AgentHost.settle(host, "timed-run", :timed_out)

      assert {:ok, ^host, %{status: :timed_out, settled?: false, active_runs: 0}} =
               AgentHost.settle(host, "timed-run", :timed_out)

      assert {:ok, next_host, %{status: :accepted}} = AgentHost.submit(host, "agent")
      assert next_host.agents["agent"].active_runs == 1
    end

    test "stops hosted agents and preserves unrelated agent availability" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 2})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent_a", lifecycle: :hosted, owner: nil})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent_b", lifecycle: :hosted, owner: nil})

      assert {:ok, host} = AgentHost.stop(host, "agent_a")

      assert {:error, %Backplane.AgentRuntime.Error{}} = AgentHost.submit(host, "agent_a")
      assert {:ok, _host, %{status: :accepted}} = AgentHost.submit(host, "agent_b")
    end
  end
end
