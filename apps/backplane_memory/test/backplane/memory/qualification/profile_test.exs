defmodule Backplane.Memory.Qualification.ProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Qualification.Profile

  test "performance preserves authoritative thresholds" do
    assert {:ok, :performance} = Profile.parse("performance")
    assert Profile.authoritative?(:performance)

    assert Profile.thresholds(:performance) == %{
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
  end

  test "ci scales only hardware-dependent thresholds to ten percent" do
    assert {:ok, :ci} = Profile.parse("ci")
    refute Profile.authoritative?(:ci)

    assert Profile.thresholds(:ci) == %{
             qualification: %{
               ingest_events_per_second_min: 50.0,
               projection_p95_lag_ms_max_exclusive: 100_000.0,
               consolidation_coverage_min: 0.95
             },
             eval: %{
               recall_any_at_5_min: 0.95,
               retrieval_fusion_p95_ms_max_exclusive: 3_000.0,
               e2e_p95_ms_max_exclusive: 8_000.0
             }
           }
  end

  test "rejects unknown profiles" do
    assert {:error, :invalid_profile} = Profile.parse("fast")
    assert {:error, :invalid_profile} = Profile.parse(nil)
  end
end
