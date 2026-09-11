defmodule Backplane.AgentRuntime.AgentHostTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.AgentHost

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
    test "accepts up to quota and returns explicit overload" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      assert {:ok, _host, %{status: :accepted, active_runs: 1}} = AgentHost.submit(host, "agent")
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
