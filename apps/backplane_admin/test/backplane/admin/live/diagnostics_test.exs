defmodule Backplane.Admin.DiagnosticsTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.Diagnostics.{Events, Issues, Projector, ReportScheduler, Sources}
  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.Repo

  test "navigates an issue and its run with bounded reports and management feedback", %{
    conn: conn
  } do
    {issue, source} = sample_issue()
    {:ok, index, html} = live(conn, "/system/diagnostics")
    assert html =~ "Diagnostic Issues"
    assert has_element?(index, "#open-diagnostic-issue-#{issue.id}[aria-label]")

    {:ok, detail, html} = live(conn, "/system/diagnostics/issues/#{issue.id}")
    assert html =~ "Affected runs"
    assert html =~ "Fix verification"
    assert has_element?(detail, "#request-analysis")

    assert detail |> form("#diagnostics-issue-state", %{"status" => "triaged"}) |> render_submit() =~
             "Issue state updated"

    assert Issues.get(issue.id).status == "triaged"

    {:ok, _view, html} = live(conn, "/system/diagnostics/runs/#{source}/run-fixture")
    assert html =~ "Run Details"
    assert html =~ "run-fixture"
  end

  test "health, analysis settings, verification, and missing issue routes render", %{conn: conn} do
    for {path, content} <- [
          {"health", "Pending Backplane projections"},
          {"settings", "Daily calls"},
          {"resolutions", "No fix scopes have been recorded"},
          {"issues/999999999", "Diagnostic issue could not be located"}
        ] do
      assert {:ok, _view, html} = live(conn, "/system/diagnostics/" <> path)
      assert html =~ content
    end
  end

  test "splits an occurrence, then merges the resulting issue through operator controls", %{
    conn: conn
  } do
    {issue, _source} = sample_issue(2)
    [occurrence | _] = Issues.occurrences(issue.id)
    {:ok, view, _html} = live(conn, "/system/diagnostics/issues/#{issue.id}")

    view
    |> form("#diagnostics-split", %{"occurrences" => to_string(occurrence.id)})
    |> render_submit()

    [split] = Enum.reject(Issues.list(), &(&1.id == issue.id))
    assert_patch(view, "/system/diagnostics/issues/#{split.id}")
    assert %{events: 1, occurrences: 1, runs: 1} = Issues.counts(split.id)

    view |> form("#diagnostics-merge", %{"destination" => to_string(issue.id)}) |> render_submit()
    assert_patch(view, "/system/diagnostics/issues/#{issue.id}")
    assert %{events: 2, occurrences: 2, runs: 1} = Issues.counts(issue.id)

    assert {:ok, _, html} = live(conn, "/system/diagnostics/issues/#{split.id}")
    assert html =~ "Merged into"
  end

  defp sample_issue(copies \\ 1) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO skill_hosts (name, inserted_at, updated_at) VALUES ('diagnostics-ui-host', NOW(), NOW()) RETURNING id"
      )

    host_id = Ecto.UUID.load!(id)
    source = "diagnostics-ui-source"
    assert {:ok, _} = Sources.register(host_id, %{id: source, application: "fixture"})

    attrs = %{
      "schema_version" => 1,
      "event_type" => "exception",
      "event_id" => "view-event",
      "source_id" => source,
      "producer_epoch" => "boot",
      "source_sequence" => 1,
      "application" => "fixture",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "evidence" => %{"exception" => %{"type" => "FixtureError", "code" => "fixture_error"}},
      "subject" => %{"run_id" => "run-fixture"},
      "quality" => %{"redaction_policy_version" => 1}
    }

    for sequence <- 1..copies do
      id = "view-event-#{sequence}"

      event =
        attrs
        |> Map.merge(%{"event_id" => id, "source_sequence" => sequence})
        |> put_in(["subject", "attempt_id"], "attempt-#{sequence}")

      {:ok, _, digest} = Envelope.seal(event)

      assert %{"receipts" => [%{"status" => "stored"}]} =
               Events.ingest(host_id, "fixture", [Receipt.entry(event, digest)])

      persisted = Repo.get_by!(Events.Event, source_id: source, event_id: id)
      assert {:ok, :processed} = Projector.project(persisted.id)
      assert {:ok, :refreshed} = ReportScheduler.drain_once()
    end

    [issue] = Issues.list()
    {issue, source}
  end
end
