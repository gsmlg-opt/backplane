defmodule Backplane.AgentRuntime.RecoveryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Recovery

  describe "conservative recovery" do
    test "fences an old incarnation and resumes only safe unstarted work" do
      record = %{
        run_id: "run_1",
        incarnation: 1,
        effects: [
          %{effect_id: "effect_read", class: :read_only, dispatch: %{state: :not_dispatched}},
          %{
            effect_id: "effect_idempotent",
            class: :idempotent,
            dispatch: %{state: :not_dispatched}
          },
          %{effect_id: "effect_mutation", class: :mutation, dispatch: %{state: :not_dispatched}},
          %{effect_id: "effect_dispatched", class: :read_only, dispatch: %{state: :dispatched}}
        ]
      }

      assert {:ok, recovery} = Recovery.recover(record, %{incarnation: 2})

      assert recovery.fenced_incarnation == 1
      assert recovery.incarnation == 2

      assert [
               %{safe_to_resume?: true},
               %{safe_to_resume?: true},
               %{safe_to_resume?: false},
               %{
                 safe_to_resume?: false
               }
             ] = recovery.effects
    end

    test "preserves uncertainty for missing or malformed evidence" do
      record = %{run_id: "run_1", incarnation: 0, effects: [%{effect_id: "effect_malformed"}]}

      assert {:ok, recovery} = Recovery.recover(record, %{incarnation: 1})

      assert [%{safe_to_resume?: false, outcome: :unknown}] = recovery.effects
      assert [%{outcome: :unknown}] = recovery.uncertain_effects
    end

    test "rejects stale or invalid incarnations" do
      assert {:error, %Error{class: :forbidden}} =
               Recovery.recover(%{incarnation: 2}, %{incarnation: 1})

      assert {:error, %Error{class: :validation}} = Recovery.recover("invalid", %{incarnation: 1})
    end
  end
end
