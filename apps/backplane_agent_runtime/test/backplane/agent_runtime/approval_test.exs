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

  test "infinite expiry preserves approval binding checks" do
    approval = %{approval() | expires_at: :infinity, current_time: 1_000_000}
    assert {:ok, :approved} = Approval.decide(approval, decision(:approved))
    assert {:ok, :denied} = Approval.decide(approval, decision(:denied))

    assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
             Approval.decide(approval, %{decision(:approved) | arguments_digest: "changed"})

    assert {:error, %Backplane.AgentRuntime.Error{}} =
             Approval.decide(%{approval | current_time: nil}, decision(:approved))
  end

  describe "approval" do
    test "requires a resolver identity for approved and denied decisions" do
      for outcome <- [:approved, :denied] do
        assert {:error, %Backplane.AgentRuntime.Error{class: :validation}} =
                 Approval.decide(approval(), Map.delete(decision(outcome), :resolver_id))
      end
    end

    test "rejects blank and nonbinary resolver identities for approved and denied decisions" do
      for outcome <- [:approved, :denied],
          resolver_id <- [nil, "", " \t\r\n", "\u00A0\u2003", :untrusted, 42, false, %{}, []] do
        assert {:error, %Backplane.AgentRuntime.Error{class: :validation}} =
                 Approval.decide(approval(), %{decision(outcome) | resolver_id: resolver_id})
      end
    end

    test "accepts nonblank binary resolver identities for approved and denied decisions" do
      for outcome <- [:approved, :denied],
          resolver_id <- ["authenticated-host", " host ", <<255>>] do
        assert {:ok, ^outcome} =
                 Approval.decide(approval(), %{decision(outcome) | resolver_id: resolver_id})
      end
    end

    test "rejects the model resolver identity for approved and denied decisions" do
      for outcome <- [:approved, :denied] do
        assert {:error,
                %Backplane.AgentRuntime.Error{
                  class: :forbidden,
                  message: "model cannot self-approve"
                }} = Approval.decide(approval(), %{decision(outcome) | resolver_id: "run_1"})
      end
    end

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
