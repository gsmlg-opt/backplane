defmodule Backplane.Memory.Operations.Rollout do
  @moduledoc "Operational controls for the canonical Memory processing pipeline."

  @pipeline %{key: "memory.pipeline.enabled", label: "Background processing"}
  @stages [
    %{key: "memory.window_summaries.enabled", label: "Window summaries", gate: :window_summaries},
    %{
      key: "memory.session_summary_v2.enabled",
      label: "Session summaries",
      gate: :session_summary_v2
    },
    %{
      key: "memory.fact_extraction_v2.enabled",
      label: "Fact extraction",
      gate: :fact_extraction_v2
    },
    %{
      key: "memory.procedure_extraction_v2.enabled",
      label: "Procedure extraction",
      gate: :procedure_extraction_v2
    }
  ]
  @stage_gates Map.new(@stages, &{&1.gate, &1.key})

  def state do
    values =
      settings().get_many([@pipeline.key, "memory.llm_model" | Enum.map(@stages, & &1.key)])

    enabled = values[@pipeline.key] == true
    model = values["memory.llm_model"]
    model_ready = is_binary(model) and String.trim(model) != ""

    %{
      pipeline: Map.merge(@pipeline, %{configured: enabled, effective: enabled, blocked: false}),
      later:
        Enum.map(@stages, fn stage ->
          configured = values[stage.key] == true
          model_required = stage.gate in [:fact_extraction_v2, :procedure_extraction_v2]
          effective = configured and enabled and (not model_required or model_ready)

          reason =
            cond do
              not configured -> "disabled"
              not enabled -> "pipeline_disabled"
              model_required and not model_ready -> "no_model"
              true -> nil
            end

          Map.merge(stage, %{
            available: true,
            configured: configured,
            effective: effective,
            blocked: configured and not effective,
            reason: reason,
            applies: "live"
          })
        end)
    }
  end

  def subscribe, do: settings().subscribe()

  def set_gate(:pipeline, value) when is_boolean(value),
    do: persist(@pipeline.key, value, [])

  def set_gate(gate, value) when is_map_key(@stage_gates, gate) and is_boolean(value) do
    expectations = if value, do: [{@pipeline.key, true}], else: []

    case persist(Map.fetch!(@stage_gates, gate), value, expectations) do
      {:error, {:condition_failed, _}} -> {:error, {:dependency, :pipeline, true}}
      result -> result
    end
  end

  def set_gate(gate, _value) when gate != :pipeline and not is_map_key(@stage_gates, gate),
    do: {:error, :invalid_gate}

  def set_gate(_gate, _value), do: {:error, :invalid_boolean}

  defp persist(key, value, expectations) do
    case settings().set_if(key, value, expectations) do
      :ok ->
        if value, do: Backplane.Memory.Workers.StageResumeWorker.enqueue()
        :ok

      result ->
        result
    end
  end

  defp settings do
    Application.get_env(:backplane_memory, :settings_adapter, Backplane.Settings)
  end
end
