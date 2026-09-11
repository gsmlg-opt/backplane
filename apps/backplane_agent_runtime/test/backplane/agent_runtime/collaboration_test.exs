defmodule Backplane.AgentRuntime.CollaborationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.AgentHost
  alias Backplane.AgentRuntime.Collaboration
  alias Backplane.AgentRuntime.Error

  describe "opt-in tools" do
    test "registers only selected tool names" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, tools} =
        Collaboration.register_tools(host, tools: [:agent_discover, :run_status])

      assert tools == [:agent_discover, :run_status]
      assert is_map(host)
    end

    test "rejects unknown tool names" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      assert {:error, %Error{}} =
               Collaboration.register_tools(host, tools: [:model_self_approve])
    end
  end

  describe "visibility and discovery" do
    test "returns visible agents and hides other namespaces" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "ns1:agent", lifecycle: :hosted, owner: nil})

      assert {:ok, ["ns1:agent"]} = Collaboration.discover(host, "ns1:viewer", "ns1:")
      assert {:ok, []} = Collaboration.discover(host, "ns2:viewer", "ns1:")
    end
  end

  describe "messaging and delegation" do
    test "delegates bounded work to a visible target" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "target", lifecycle: :hosted, owner: nil})

      assert {:ok, %{receipt: receipt}} =
               Collaboration.delegate(host, %{
                 target_agent_id: "target",
                 delegated_from: "run_1",
                 idempotency_key: "key_1"
               })

      assert receipt.status == :accepted
      assert receipt.delegated_from == "run_1"
    end

    test "notifications do not start a task" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      assert {:ok, _host, %{delivered: true}} =
               Collaboration.send(host, %{
                 sender: "sender",
                 recipient: "recipient",
                 kind: :notification,
                 correlation_id: "correlation_1",
                 payload: %{"text" => "hello"},
                 expires_at: 100
               })
    end
  end

  describe "interaction" do
    test "asks the configured resolver and rejects headless requests" do
      assert {:ok, %{resolved: true}} =
               Collaboration.ask_user(%{correlation_id: "correlation_1"}, "resolver_1")

      assert {:error, %Error{class: :forbidden}} =
               Collaboration.ask_user(%{correlation_id: "correlation_1"}, nil)
    end
  end
end
