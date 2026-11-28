defmodule Backplane.Diagnostics.ResolutionsTest do
  use ExUnit.Case, async: true

  alias Backplane.Diagnostics.{
    Events,
    Issues,
    Projector,
    ReportScheduler,
    Reports,
    Resolutions,
    Sources
  }

  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.Repo

  @source "resolution-test-source"
  @fix_sha String.duplicate("b", 40)
  @old_sha String.duplicate("a", 40)

  setup tags do
    BackplaneDataCase.setup_sandbox(Repo, tags)

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO skill_hosts (name,inserted_at,updated_at) VALUES ('resolution-host', NOW(), NOW()) RETURNING id"
      )

    host = Ecto.UUID.load!(id)
    assert {:ok, _} = Sources.register(host, %{id: @source, application: "test"})
    %{host: host, at: DateTime.utc_now()}
  end

  test "tests, deployed coverage, recurrence and late old builds remain distinct", %{
    host: host,
    at: at
  } do
    project(host, anomaly(1, "old", @old_sha, DateTime.add(at, -60, :second)))
    assert [issue] = Issues.list()
    assert {:ok, :refreshed} = ReportScheduler.drain_once()
    assert %Reports.Report{revision: 1, body: %{} = report} = Reports.get(issue.id)
    assert report["issue_id"] == issue.id

    assert {:ok, resolution} =
             Resolutions.propose(
               issue.id,
               %{
                 repository: "fixture/app",
                 fix_sha: @fix_sha,
                 source_ids: [@source],
                 releases: ["fixed"],
                 workload: "regression-fixture",
                 min_runs: 2,
                 min_seconds: 5
               },
               "admin"
             )

    assert {:ok, _} = Resolutions.record_check(resolution.id, "reproduced", "fixture:v1", "admin")

    assert {:ok, _} =
             Resolutions.record_check(resolution.id, "fixed_in_test", "suite:fixed", "admin")

    assert {:ok, ready} = Resolutions.implementation(resolution.id, "merged", "admin")
    assert ready.deployment_state == "not_observed"
    assert ready.observation_state == "insufficient_coverage"
    assert Issues.get(issue.id).status == "open"

    observed_at = DateTime.add(ready.activation_at, 1, :second)
    project(host, terminal(2, "run-a", "fixed", @fix_sha, observed_at))
    assert Issues.get(issue.id).status == "observing"
    assert Resolutions.coverage(resolution.id).healthy == 1

    project(host, terminal(3, "run-b", "fixed", @fix_sha, DateTime.add(observed_at, 6, :second)))
    assert Issues.get(issue.id).status == "resolved"
    assert Resolutions.coverage(resolution.id).healthy == 2
    assert Resolutions.get(resolution.id).observation_state == "healthy_observation"

    project(host, anomaly(4, "old", @old_sha, DateTime.add(at, -30, :second)))
    assert Issues.get(issue.id).status == "resolved"
    assert Resolutions.get(resolution.id).recurrence_event_key == nil

    repeated = project(host, anomaly(5, "fixed", @fix_sha, DateTime.add(observed_at, 8, :second)))
    assert Issues.get(issue.id).status == "reopened"

    assert %Resolutions.Resolution{recurrence_event_key: key, observation_state: "recurred"} =
             Resolutions.get(resolution.id)

    assert key == repeated.id
    assert {:ok, :refreshed} = ReportScheduler.drain_once()
    assert %Reports.Report{revision: 2, change: "reopened"} = Reports.get(issue.id)
  end

  defp anomaly(n, release, sha, date) do
    event(n, "exception", "failure-#{n}", release, sha, date, "failure")
    |> Map.put("evidence", %{
      "exception" => %{"type" => "FixtureError", "code" => "fixture_error"}
    })
  end

  defp terminal(n, run, release, sha, date),
    do: event(n, "run_finished", run, release, sha, date, "success")

  defp event(n, type, run, release, sha, observed, outcome) do
    %{
      "schema_version" => 1,
      "event_type" => type,
      "event_id" => "event-#{n}",
      "source_id" => @source,
      "application" => "test",
      "producer_epoch" => "boot",
      "source_sequence" => n,
      "occurred_at" => DateTime.to_iso8601(observed),
      "subject" => %{"run_id" => run, "revision" => 1},
      "version" => %{"release" => release, "git_sha" => sha, "repository" => "fixture/app"},
      "result" => %{
        "outcome" => outcome,
        "phase" => "test",
        "workload" => "regression-fixture",
        "error_class" => "software_defect"
      },
      "quality" => %{"redaction_policy_version" => 1}
    }
  end

  defp project(host, event) do
    {:ok, _, digest} = Envelope.seal(event)

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Events.ingest(host, "batch", [Receipt.entry(event, digest)])

    stored = Repo.get_by!(Events.Event, source_id: @source, event_id: event["event_id"])
    assert {:ok, :processed} = Projector.project(stored.id)
    stored
  end
end
