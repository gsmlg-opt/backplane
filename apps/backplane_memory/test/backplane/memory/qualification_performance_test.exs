defmodule Backplane.Memory.Qualification.PerformanceTest do
  use Backplane.Memory.DataCase, async: false

  @moduletag :memory_qualification_runtime
  @moduletag timeout: 120_000

  alias Backplane.Memory.Qualification.Runner

  test "batched server ingest sustains 500 events per second without lost or duplicate effects" do
    run_id = "qualification-ingest-#{System.unique_integer([:positive])}"

    assert {:ok, measurement} =
             Runner.measure_ingest(
               run_id: run_id,
               event_count: 2_000,
               batch_size: 100,
               warmup_event_count: 1_000,
               max_concurrency: 5
             )

    assert measurement.accepted == 2_000
    assert measurement.persisted == 2_000
    assert measurement.duplicate_effects == 0
    assert measurement.events_per_second >= 500
    assert measurement.batch_size == 100
    assert measurement.batch_count == 20
    assert measurement.concurrency == 5
    assert measurement.projection_jobs_durable == 2_000
    assert measurement.projection_job_event_ids_unique == 2_000
    assert measurement.measured_path =~ "Oban projection job commit"
  end

  test "deterministic observation, session, activity, and replay projections stay below 10s p95" do
    run_id = "qualification-projection-#{System.unique_integer([:positive])}"

    assert {:ok, measurement} =
             Runner.measure_projection(run_id: run_id, sample_count: 100)

    assert measurement.samples == 100
    assert measurement.jobs_durable == 100
    assert measurement.jobs_completed == 100
    assert measurement.projectors == ~w(activity observations replay session)
    assert measurement.complete_subjects == 100
    assert measurement.p95_lag_ms < 10_000
    assert measurement.worker == "Backplane.Memory.Workers.ProjectionRepairWorker"
    assert measurement.queue_execution =~ "Oban manual drain"
  end

  test "at least 95 percent of eligible closed sessions are summarized within four hours" do
    run_id = "qualification-consolidation-#{System.unique_integer([:positive])}"

    assert {:ok, measurement} =
             Runner.measure_consolidation(run_id: run_id, session_count: 20)

    assert measurement.eligible == 20
    assert measurement.summarized_within_four_hours >= 19
    assert measurement.coverage >= 0.95
    assert measurement.without_provenance == 0
  end

  test "mixed transient failure, retry, and database contention has exactly-once effects" do
    run_id = "qualification-resilience-#{System.unique_integer([:positive])}"

    assert {:ok, measurement} =
             Runner.measure_resilience(run_id: run_id, event_count: 100, contention_workers: 4)

    assert measurement.retryable_failures_observed == 100
    assert measurement.accepted == 100
    assert measurement.persisted == 100
    assert measurement.duplicate_deliveries == 300
    assert measurement.duplicate_effects == 0
    assert measurement.permanent_failures == 0
    assert measurement.contention_workers == 4
  end

  test "runs the complete authoritative workload and returns a reproducible passing report" do
    assert {:ok, report} =
             Runner.run(
               run_id: "qualification-report-#{System.unique_integer([:positive])}",
               ingest_max_concurrency: 5,
               profile: :performance
             )

    assert report.profile == :performance
    assert report.performance_authoritative
    assert report.passed
    assert Enum.all?(report.gates, fn {_gate, passed?} -> passed? end)
    assert report.metrics.ingest.events_per_second >= 500
    assert report.metrics.ingest.concurrency == 5
    assert report.metrics.projection.p95_lag_ms < 10_000
    assert report.metrics.consolidation.coverage >= 0.95
    assert report.metrics.outage.simulated_hours == 24

    assert report.configuration.command ==
             "MIX_ENV=test mix memory.qualify --profile performance --report <path>"

    assert is_binary(report.configuration.runtime.elixir)
    assert report.configuration.cross_release_outage_test =~ "m18_outage_qualification_test.exs"
  end
end
