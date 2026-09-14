defmodule Backplane.AgentRuntime.CollaborationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.AgentHost
  alias Backplane.AgentRuntime.Collaboration
  alias Backplane.AgentRuntime.Error

  describe "opt-in tools" do
    test "registers only collaboration operations backed by current host state" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, tools} =
        Collaboration.register_tools(host, tools: [:agent_discover, :run_status])

      assert tools == [:agent_discover, :run_status]
      assert is_map(host)
    end

    test "does not advertise deferred collaboration operations" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      for tool <- [
            :agent_spawn,
            :agent_delegate,
            :agent_send,
            :run_wait,
            :run_cancel,
            :ask_user
          ] do
        assert {:error, %Error{class: :unsupported_capability}} =
                 Collaboration.register_tools(host, tools: [tool])
      end
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

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "ns2:agent", lifecycle: :hosted, owner: nil})

      assert {:ok, ["ns1:agent"]} = Collaboration.discover(host, "ns1:viewer", "ns1:")
      assert {:ok, []} = Collaboration.discover(host, "ns2:viewer", "ns1:")

      assert {:error, %Error{class: :validation}} =
               Collaboration.discover(host, "ns1:viewer", "")

      assert {:error, %Error{class: :validation}} =
               Collaboration.discover(host, "ns1:viewer", "ns")
    end
  end

  describe "messaging and delegation" do
    test "returns explicit unavailability instead of delegation or delivery receipts" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 2, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "target", lifecycle: :hosted, owner: nil})

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.delegate(host, %{
                 target_agent_id: "target",
                 delegated_from: "run_1",
                 idempotency_key: "key_1"
               })

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.send(host, %{
                 sender: "sender",
                 recipient: "target",
                 kind: :notification,
                 correlation_id: "correlation_1",
                 payload: %{"text" => "hello"},
                 expires_at: 100
               })

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.spawn(host, %{agent_id: "child"})

      assert host.agents["target"].active_runs == 0
    end
  end

  describe "run state and deferred controls" do
    test "reports only recorded host run state" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 1, max_active_runs: 1})

      {:ok, host, _} =
        AgentHost.register(host, %{agent_id: "agent", lifecycle: :hosted, owner: nil})

      assert {:ok, host, %{run_id: "run_1", status: :accepted}} =
               AgentHost.submit(host, "agent", %{run_id: "run_1"})

      assert {:ok, %{run_id: "run_1", agent_id: "agent", status: :accepted}} =
               Collaboration.status(host, "run_1")

      assert {:error, %Error{class: :not_found}} = Collaboration.status(host, "missing")
    end

    test "wait, cancel, and user interaction are explicitly unavailable" do
      {:ok, host} = AgentHost.new("runtime_1", %{max_agents: 1, max_active_runs: 1})

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.wait(host, "run_1")

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.cancel(host, "run_1")

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.ask_user(%{correlation_id: "correlation_1"}, "resolver_1")

      assert {:error, %Error{class: :unsupported_capability}} =
               Collaboration.ask_user(%{correlation_id: "correlation_1"}, nil)
    end
  end
end
