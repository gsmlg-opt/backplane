defmodule Backplane.AgentRuntime.GoalBridgeTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{GoalBridge, Usage}

  test "cumulative snapshots and repeated terminal usage produce one attempt report" do
    {:ok, ledger} = Usage.new()

    snapshots = [
      %{input_tokens: 50, cached_tokens: 40, output_tokens: 2},
      %{input_tokens: 50, cached_tokens: 40, output_tokens: 7},
      %{input_tokens: 50, cached_tokens: 40, output_tokens: 7}
    ]

    identity = %{run_id: "r", incarnation: 1, attempt_id: "a", step_id: "s"}
    assert {:ok, ledger, report} = GoalBridge.report(ledger, snapshots, identity)
    assert report.identity == "r:1:a"
    assert report.output_tokens == 7
    assert Usage.totals(ledger).output_tokens == 7
    assert {:ok, ledger, ^report} = GoalBridge.report(ledger, snapshots, identity)
    assert Usage.totals(ledger).output_tokens == 7
  end

  test "missing usage stays unknown, including cached input" do
    {:ok, ledger} = Usage.new()
    identity = %{run_id: "r", incarnation: 1, attempt_id: "a", step_id: "s"}

    assert {:ok, _, %{input_tokens: :unknown, cached_tokens: :unknown, output_tokens: :unknown}} =
             GoalBridge.report(ledger, [], identity)
  end

  test "regressing cumulative metrics and invalid values fail before accounting" do
    {:ok, ledger} = Usage.new()
    identity = %{run_id: "r", incarnation: 1, attempt_id: "a", step_id: "s"}

    for snapshots <- [[%{output_tokens: 8}, %{output_tokens: 7}], [%{input_tokens: -1}], [:bad]] do
      assert {:error, %{class: :validation}} = GoalBridge.report(ledger, snapshots, identity)
    end
  end
end
