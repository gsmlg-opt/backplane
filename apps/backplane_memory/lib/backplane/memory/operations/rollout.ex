defmodule Backplane.Memory.Operations.Rollout do
  @moduledoc false

  @gates %{
    pipeline: %{key: "memory.pipeline.enabled", label: "Pipeline"},
    events: %{key: "memory.events.enabled", label: "Events"},
    dual_write: %{key: "memory.events.dual_write", label: "Dual Write"}
  }

  @later [
    %{key: "memory.window_summaries.enabled", label: "Window Summaries", available: false},
    %{
      key: "memory.session_summary_v2.enabled",
      label: "Session Summary V2",
      available: false
    },
    %{
      key: "memory.fact_extraction_v2.enabled",
      label: "Fact Extraction V2",
      available: false
    },
    %{
      key: "memory.procedure_extraction_v2.enabled",
      label: "Procedure Extraction V2",
      available: false
    },
    %{key: "memory.recall_v2.enabled", label: "Recall V2", available: false}
  ]

  def state do
    gate_keys =
      Map.new(@gates, fn {gate, metadata} ->
        {gate, metadata.key}
      end)

    values = settings().get_many(Map.values(gate_keys))

    configured =
      Map.new(gate_keys, fn {gate, key} ->
        {gate, Map.fetch!(values, key) == true}
      end)

    pipeline_effective = configured.pipeline
    events_effective = pipeline_effective and configured.events
    dual_write_effective = events_effective and configured.dual_write

    %{
      pipeline:
        gate_state(
          :pipeline,
          configured.pipeline,
          pipeline_effective
        ),
      events:
        gate_state(
          :events,
          configured.events,
          events_effective
        ),
      dual_write:
        gate_state(
          :dual_write,
          configured.dual_write,
          dual_write_effective
        ),
      later: @later
    }
  end

  def subscribe, do: settings().subscribe()

  def set_gate(gate, _value) when not is_map_key(@gates, gate),
    do: {:error, :invalid_gate}

  def set_gate(_gate, value) when not is_boolean(value),
    do: {:error, :invalid_boolean}

  def set_gate(gate, value) do
    requirements = transition_requirements(gate, value)

    expectations =
      Enum.map(requirements, fn {required_gate, expected, _error} ->
        {gate_key(required_gate), expected}
      end)

    case settings().set_if(gate_key(gate), value, expectations) do
      {:error, {:condition_failed, failed_key}} ->
        {_gate, _expected, error} =
          Enum.find(requirements, fn {required_gate, _expected, _error} ->
            gate_key(required_gate) == failed_key
          end)

        {:error, error}

      result ->
        result
    end
  end

  defp transition_requirements(:pipeline, true) do
    [
      {:events, false, {:blocked_descendant, :events}},
      {:dual_write, false, {:blocked_descendant, :dual_write}}
    ]
  end

  defp transition_requirements(:events, true) do
    [
      {:pipeline, true, {:dependency, :pipeline, true}},
      {:dual_write, false, {:dependency, :dual_write, false}}
    ]
  end

  defp transition_requirements(:dual_write, true) do
    [
      {:pipeline, true, {:dependency, :events, true}},
      {:events, true, {:dependency, :events, true}}
    ]
  end

  defp transition_requirements(:dual_write, false), do: []

  defp transition_requirements(:events, false) do
    [{:dual_write, false, {:dependency, :dual_write, false}}]
  end

  defp transition_requirements(:pipeline, false) do
    [
      {:events, false, {:blocked_descendant, :events}},
      {:dual_write, false, {:blocked_descendant, :dual_write}}
    ]
  end

  defp gate_state(gate, configured, effective) do
    @gates
    |> Map.fetch!(gate)
    |> Map.merge(%{
      configured: configured,
      effective: effective,
      blocked: configured and not effective
    })
  end

  defp gate_key(gate) do
    @gates
    |> Map.fetch!(gate)
    |> Map.fetch!(:key)
  end

  defp settings do
    Application.get_env(
      :backplane_memory,
      :settings_adapter,
      Backplane.Settings
    )
  end
end
