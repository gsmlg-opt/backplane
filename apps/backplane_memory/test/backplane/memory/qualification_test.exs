defmodule Backplane.Memory.QualificationTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Qualification

  test "evaluates every M18 NFR gate from measured evidence" do
    measurements = %{
      ingest: %{
        accepted: 1_000,
        persisted: 1_000,
        duplicate_effects: 0,
        events_per_second: 750.0,
        projection_jobs_durable: 1_000,
        projection_job_event_ids_unique: 1_000
      },
      projection: %{
        samples: 100,
        jobs_durable: 100,
        jobs_completed: 100,
        complete_subjects: 100,
        p95_lag_ms: 1_200
      },
      consolidation: %{eligible: 100, summarized_within_four_hours: 97},
      outage: %{locally_accepted: 500, delivered: 500, persisted: 500, duplicate_effects: 0},
      resilience: %{
        accepted: 200,
        persisted: 200,
        duplicate_effects: 0,
        permanent_failures: 0,
        retryable_failures_observed: 200,
        duplicate_deliveries: 600,
        contention_workers: 4
      }
    }

    report = Qualification.evaluate(measurements, generated_at: ~U[2026-08-12 00:00:00Z])

    assert report.schema_version == 1
    assert report.suite == "memory-v2-m18-qualification"
    assert report.generated_at == "2026-08-12T00:00:00Z"

    assert report.thresholds == %{
             ingest_events_per_second_min: 500,
             projection_p95_lag_ms_max_exclusive: 10_000,
             consolidation_coverage_min: 0.95
           }

    assert report.metrics.consolidation.coverage == 0.97

    assert report.gates == %{
             ingest_throughput: true,
             accepted_event_integrity: true,
             projection_lag: true,
             consolidation_coverage: true,
             outage_recovery: true,
             retry_contention_failure: true
           }

    assert report.passed
    assert {:ok, decoded} = report |> Qualification.encode_report() |> Jason.decode()
    assert decoded["passed"]
    assert decoded["configuration"]["reproducible"]
  end

  test "fails closed when a measurement is absent or a threshold is missed" do
    absent = Qualification.evaluate(%{})
    refute absent.passed
    assert Enum.all?(absent.gates, fn {_gate, passed?} -> passed? == false end)

    report =
      Qualification.evaluate(%{
        ingest: %{
          accepted: 100,
          persisted: 99,
          duplicate_effects: 1,
          events_per_second: 499.9,
          projection_jobs_durable: 99,
          projection_job_event_ids_unique: 99
        },
        projection: %{
          samples: 0,
          jobs_durable: 0,
          jobs_completed: 0,
          complete_subjects: 0,
          p95_lag_ms: nil
        },
        consolidation: %{eligible: 0, summarized_within_four_hours: 0},
        outage: %{locally_accepted: 1, delivered: 0, persisted: 0, duplicate_effects: 0},
        resilience: %{
          accepted: 1,
          persisted: 0,
          duplicate_effects: 0,
          permanent_failures: 1,
          retryable_failures_observed: 0,
          duplicate_deliveries: 0,
          contention_workers: 1
        }
      })

    refute report.passed
    assert Enum.all?(report.gates, fn {_gate, passed?} -> passed? == false end)
  end

  test "does not pass ingest or projection gates without durable production-path jobs" do
    measurements = %{
      ingest: %{
        accepted: 500,
        persisted: 500,
        duplicate_effects: 0,
        events_per_second: 900.0,
        projection_jobs_durable: 0,
        projection_job_event_ids_unique: 0
      },
      projection: %{
        samples: 100,
        jobs_durable: 100,
        jobs_completed: 0,
        complete_subjects: 100,
        p95_lag_ms: 100
      }
    }

    report = Qualification.evaluate(measurements)

    refute report.gates.ingest_throughput
    refute report.gates.projection_lag
    refute report.passed
  end
end

defmodule Backplane.Memory.Qualification.IngestTest do
  use Backplane.Memory.DataCase, async: false

  @moduletag :memory_qualification_runtime
  @moduletag timeout: 120_000

  alias Backplane.Memory.Qualification.Runner

  test "batched server ingest sustains 500 events per second without lost or duplicate effects" do
    run_id = "qualification-ingest-#{System.unique_integer([:positive])}"

    assert {:ok, measurement} =
             Runner.measure_ingest(run_id: run_id, event_count: 500, batch_size: 100)

    assert measurement.accepted == 500
    assert measurement.persisted == 500
    assert measurement.duplicate_effects == 0
    assert measurement.events_per_second >= 500
    assert measurement.batch_size == 100
    assert measurement.batch_count == 5
    assert measurement.concurrency == 5
    assert measurement.projection_jobs_durable == 500
    assert measurement.projection_job_event_ids_unique == 500
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

  test "runs the complete bounded workload and returns a reproducible passing report" do
    assert {:ok, report} =
             Runner.run(run_id: "qualification-report-#{System.unique_integer([:positive])}")

    assert report.passed
    assert Enum.all?(report.gates, fn {_gate, passed?} -> passed? end)
    assert report.metrics.ingest.events_per_second >= 500
    assert report.metrics.projection.p95_lag_ms < 10_000
    assert report.metrics.consolidation.coverage >= 0.95
    assert report.metrics.outage.simulated_hours == 24
    assert report.configuration.command == "MIX_ENV=test mix memory.qualify --report <path>"
    assert is_binary(report.configuration.runtime.elixir)
    assert report.configuration.cross_release_outage_test =~ "m18_outage_qualification_test.exs"
  end
end
