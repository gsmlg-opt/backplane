defmodule Backplane.AgentRuntime.ApprovalTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Approval

  defp approval do
    %{
      approval_id: "approval_1",
      run_id: "run_1",
      tool_name: "example",
      tool_revision: 2,
      arguments_digest: "digest_1",
      current_time: 10,
      expires_at: 20
    }
  end

  defp decision(decision) do
    %{
      decision: decision,
      approval_id: "approval_1",
      tool_name: "example",
      tool_revision: 2,
      arguments_digest: "digest_1",
      resolver_id: "resolver_1"
    }
  end

  describe "approval" do
    test "approves a valid decision before expiry" do
      assert {:ok, :approved} = Approval.decide(approval(), decision(:approved))
    end

    test "rejects expired approvals and invalid decisions" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Approval.decide(approval(), decision(:self_approved))

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Approval.decide(%{current_time: 10, expires_at: 20}, %{decision: :approved})
    end

    test "rejects changed tool revision, arguments digest, and model self-approval" do
      approval = approval()

      assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
               Approval.decide(approval, %{decision(:approved) | tool_revision: "2"})

      assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
               Approval.decide(
                 approval,
                 %{decision(:approved) | arguments_digest: "changed"}
               )

      assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
               Approval.decide(approval, %{decision(:approved) | resolver_id: "run_1"})
    end
  end
end
