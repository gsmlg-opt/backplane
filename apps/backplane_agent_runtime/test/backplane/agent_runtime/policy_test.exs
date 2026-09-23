defmodule Backplane.AgentRuntime.PolicyTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Policy
  alias Backplane.AgentRuntime.ToolRegistry

  describe "tool registry" do
    test "registers and looks up a versioned descriptor" do
      {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor())

      assert {:ok, descriptor} = ToolRegistry.lookup(registry, "example")
      assert descriptor.tool_revision == 1
    end

    test "rejects missing tool name or revision" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               ToolRegistry.register(%ToolRegistry{}, %{})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               ToolRegistry.lookup(%ToolRegistry{}, "missing")
    end
  end

  describe "policy" do
    test "authorizes a registered tool with explicit grants" do
      assert {:ok, %{status: :authorized}} =
               Policy.authorize_tool(
                 %{caller: "agent_1", run_id: "run_1", grants: ["example"], tool_revision: 1},
                 %{tool_name: "example", tool_revision: 1},
                 %{tool_name: "example", run_id: "run_1", arguments: %{}}
               )
    end

    test "authorizes heterogeneous descriptor revisions with per-tool revision grants" do
      authority = %{
        caller: "agent_1",
        run_id: "run_1",
        grants: ["example", "other"],
        tool_revisions: %{"example" => 1, "other" => 2}
      }

      assert {:ok, %{status: :authorized}} =
               Policy.authorize_tool(
                 authority,
                 %{tool_name: "other", tool_revision: 2},
                 %{tool_name: "other", run_id: "run_1", arguments: %{}}
               )

      assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
               Policy.authorize_tool(
                 authority,
                 %{tool_name: "other", tool_revision: 3},
                 %{tool_name: "other", run_id: "run_1", arguments: %{}}
               )
    end

    test "rejects unauthorized tools" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Policy.authorize_tool(
                 %{caller: "agent_1", run_id: "run_1", grants: [], tool_revision: 1},
                 %{tool_name: "example", tool_revision: 1},
                 %{tool_name: "example", run_id: "run_1", arguments: %{}}
               )
    end

    test "rejects run identity mismatch and delegated authority expansion" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Policy.authorize_tool(
                 %{caller: "agent_1", run_id: "run_1", grants: ["example"], tool_revision: 1},
                 descriptor(),
                 %{tool_name: "example", run_id: "run_2", arguments: %{}}
               )

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Policy.authorize_tool(
                 %{caller: "agent_1", run_id: "run_1", grants: ["example"], tool_revision: 1},
                 descriptor(),
                 %{
                   tool_name: "example",
                   run_id: "run_1",
                   delegated_from: "peer_run",
                   arguments: %{}
                 }
               )
    end
  end

  defp descriptor do
    %{
      tool_name: "example",
      tool_revision: 1,
      safety: %{read_only: false, retry_safe: true, parallel_safe: false}
    }
  end

  defp invalid_descriptor do
    %{tool_name: "example", tool_revision: 1}
  end

  describe "tool registry safety metadata" do
    test "requires safety metadata" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               ToolRegistry.register(%ToolRegistry{}, invalid_descriptor())
    end
  end
end
