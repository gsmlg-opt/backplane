defmodule Backplane.Memory.Qualification.Profile do
  @moduledoc "Threshold profiles for authoritative hardware and GitHub smoke qualification."

  @ci_scale 0.1
  @performance_thresholds %{
    qualification: %{
      ingest_events_per_second_min: 500,
      projection_p95_lag_ms_max_exclusive: 10_000,
      consolidation_coverage_min: 0.95
    },
    eval: %{
      recall_any_at_5_min: 0.95,
      retrieval_fusion_p95_ms_max_exclusive: 300,
      e2e_p95_ms_max_exclusive: 800
    }
  }

  def parse("performance"), do: {:ok, :performance}
  def parse("ci"), do: {:ok, :ci}
  def parse(_profile), do: {:error, :invalid_profile}

  def authoritative?(:performance), do: true
  def authoritative?(:ci), do: false

  def thresholds(:performance), do: @performance_thresholds

  def thresholds(:ci) do
    @performance_thresholds
    |> put_in(
      [:qualification, :ingest_events_per_second_min],
      @performance_thresholds.qualification.ingest_events_per_second_min * @ci_scale
    )
    |> put_in(
      [:qualification, :projection_p95_lag_ms_max_exclusive],
      @performance_thresholds.qualification.projection_p95_lag_ms_max_exclusive / @ci_scale
    )
    |> put_in(
      [:eval, :retrieval_fusion_p95_ms_max_exclusive],
      @performance_thresholds.eval.retrieval_fusion_p95_ms_max_exclusive / @ci_scale
    )
    |> put_in(
      [:eval, :e2e_p95_ms_max_exclusive],
      @performance_thresholds.eval.e2e_p95_ms_max_exclusive / @ci_scale
    )
  end
end
