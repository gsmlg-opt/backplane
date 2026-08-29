defmodule Mix.Tasks.Memory.QualifyTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.Qualification.Runner

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "writes the complete machine-readable qualification artifact", %{tmp_dir: tmp_dir} do
    report_path = Path.join(tmp_dir, "memory-v2-m18-qualification.json")

    Mix.Task.reenable("memory.qualify")
    Mix.Tasks.Memory.Qualify.run(["--report", report_path])

    assert {:ok, report} = report_path |> File.read!() |> Jason.decode()
    assert report["schema_version"] == 1
    assert report["suite"] == "memory-v2-m18-qualification"
    assert report["passed"]
    assert Enum.all?(report["gates"], fn {_gate, passed?} -> passed? end)
    assert report["configuration"]["reproducible"]
    assert report["configuration"]["workload"]["ingest_events"] == 2_000
    assert report["configuration"]["workload"]["ingest_warmup_events"] == 1_000
    assert report["configuration"]["workload"]["ingest_batch_size"] == 100
    assert report["metrics"]["ingest"]["events_per_second"] >= 500
    assert report["metrics"]["ingest"]["concurrency"] == 5
    assert report["metrics"]["ingest"]["projection_jobs_durable"] == 2_000
    assert report["metrics"]["ingest"]["projection_job_event_ids_unique"] == 2_000
    assert report["metrics"]["projection"]["jobs_durable"] == 100
    assert report["metrics"]["projection"]["jobs_completed"] == 100
    assert report["metrics"]["projection"]["complete_subjects"] == 100

    assert report["metrics"]["projection"]["worker"] ==
             "Backplane.Memory.Workers.ProjectionRepairWorker"
  end

  test "sandboxed qualification cannot exceed its safe ingest concurrency" do
    assert {:ok, report} = Runner.sandboxed_run(ingest_max_concurrency: 20)
    assert report.metrics.ingest.concurrency == 5
    assert report.metrics.ingest.projection_jobs_durable == 2_000
  end
end
