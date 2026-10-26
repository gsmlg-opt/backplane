defmodule Backplane.Memory.Operations.RolloutTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Operations}
  alias Backplane.Settings

  setup do
    keys =
      ~w(memory.pipeline.enabled memory.window_summaries.enabled memory.session_summary.enabled memory.fact_extraction.enabled memory.procedure_extraction.enabled memory.llm_model)

    snapshot = Map.new(keys, &{&1, Settings.get(&1)})
    for key <- keys, do: Settings.set(key, if(key == "memory.llm_model", do: nil, else: false))
    on_exit(fn -> Enum.each(snapshot, fn {key, value} -> Settings.set(key, value) end) end)
    :ok
  end

  test "only background processing is gated; stored configuration does not select an implementation" do
    state = Operations.rollout_state()
    refute state.pipeline.effective
    refute Map.has_key?(state, :events)
    refute Map.has_key?(state, :dual_write)
    assert length(state.later) == 4
    refute Enum.any?(state.later, &(&1.gate == :recall_v2))

    for gate <- [
          :events,
          :dual_write,
          :recall,
          :recall_v2,
          :session_summary_v2,
          :fact_extraction_v2,
          :procedure_extraction_v2,
          :unknown
        ] do
      assert {:error, :invalid_gate} = Operations.set_gate(gate, true)
    end

    for value <- [nil, 1, "true", %{}] do
      assert {:error, :invalid_boolean} = Operations.set_gate(:pipeline, value)
    end
  end

  test "pausing processing preserves configured stages and resuming makes them effective" do
    assert :ok = Operations.set_gate(:pipeline, true)
    assert :ok = Operations.set_gate(:window_summaries, true)
    assert Enum.find(Operations.rollout_state().later, &(&1.gate == :window_summaries)).effective

    assert :ok = Operations.set_gate(:pipeline, false)
    stage = Enum.find(Operations.rollout_state().later, &(&1.gate == :window_summaries))
    assert stage.configured
    refute stage.effective
    assert stage.reason == "pipeline_disabled"

    assert :ok = Operations.set_gate(:pipeline, true)
    assert Enum.find(Operations.rollout_state().later, &(&1.gate == :window_summaries)).effective
  end

  test "stage enablement requires processing and extraction requires a selected model" do
    assert {:error, {:dependency, :pipeline, true}} =
             Operations.set_gate(:fact_extraction, true)

    assert :ok = Operations.set_gate(:pipeline, true)
    assert :ok = Operations.set_gate(:fact_extraction, true)
    stage = Enum.find(Operations.rollout_state().later, &(&1.gate == :fact_extraction))
    assert stage.blocked
    assert stage.reason == "no_model"
    assert :ok = Settings.set("memory.llm_model", "provider/model")

    assert Enum.find(Operations.rollout_state().later, &(&1.gate == :fact_extraction)).effective
  end

  test "successful mutations broadcast and audit the persisted operation" do
    assert :ok = Operations.subscribe_rollout()
    assert :ok = Operations.set_gate(:pipeline, true)
    assert_receive {:setting_changed, "memory.pipeline.enabled", true}

    assert [%{target_ids: ["pipeline"], metadata: %{"result" => "updated", "value" => true}}] =
             Audit.list(operation: "memory.gate.set", limit: 1)
  end
end
