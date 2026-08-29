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

  test "ci scales hardware gates while performance remains authoritative" do
    measurements = %{
      ingest: %{
        accepted: 500,
        persisted: 500,
        duplicate_effects: 0,
        events_per_second: 75.0,
        projection_jobs_durable: 500,
        projection_job_event_ids_unique: 500
      },
      projection: %{
        samples: 100,
        jobs_durable: 100,
        jobs_completed: 100,
        complete_subjects: 100,
        p95_lag_ms: 50_000
      },
      consolidation: %{eligible: 20, summarized_within_four_hours: 20},
      outage: %{locally_accepted: 100, delivered: 100, persisted: 100, duplicate_effects: 0},
      resilience: %{
        accepted: 100,
        persisted: 100,
        duplicate_effects: 0,
        permanent_failures: 0,
        retryable_failures_observed: 100,
        duplicate_deliveries: 300,
        contention_workers: 4
      }
    }

    ci = Qualification.evaluate(measurements, profile: :ci)
    performance = Qualification.evaluate(measurements, profile: :performance)

    assert ci.profile == :ci
    refute ci.performance_authoritative
    assert ci.thresholds.ingest_events_per_second_min == 50.0
    assert ci.thresholds.projection_p95_lag_ms_max_exclusive == 100_000.0
    assert ci.gates.ingest_throughput
    assert ci.gates.projection_lag
    assert ci.passed

    assert performance.profile == :performance
    assert performance.performance_authoritative
    refute performance.gates.ingest_throughput
    refute performance.gates.projection_lag
    refute performance.passed
  end
end
