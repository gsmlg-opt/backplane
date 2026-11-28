defmodule Backplane.Diagnostics.RetentionTest do
  use ExUnit.Case, async: false

  alias Backplane.Diagnostics.{
    Evidence,
    Events,
    Issues,
    Outbox,
    Queries,
    Reports,
    Retention,
    Sources
  }

  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.Repo

  @now ~U[2099-11-28 05:00:00.000000Z]
  @ttl_key "diagnostics.retention.exception_days"

  setup context do
    BackplaneDataCase.setup_sandbox(Repo, context)

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO skill_hosts (name, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) RETURNING id",
        ["retention-host"]
      )

    host_id = Ecto.UUID.load!(id)
    {:ok, _} = Sources.register(host_id, %{id: "retention-source", application: "test"})
    %{host_id: host_id}
  end

  test "discards expired details without dropping identities, unfinished projection, or evidence state",
       %{host_id: host_id} do
    {success, active_item} = event(host_id, 1, "active", "run_finished", "success", 8)
    {failure, sealed_item} = event(host_id, 2, "sealed", "handled_error", "failure", 31)
    {young, _} = event(host_id, 3, "active", "handled_error", "failure", 8)
    {pending, _} = event(host_id, 4, "active", "run_finished", "success", 40)

    for record <- [success, failure, young] do
      Repo.delete!(Repo.get!(Outbox.Entry, record.id))
    end

    assert {:ok, _} = Events.seal_epoch(host_id, "retention-source", "sealed")

    issue = create_issue()
    snapshot = %{id: issue.id, events: [failure]}
    assert {:ok, bundle} = Evidence.freeze(snapshot, now: DateTime.add(@now, -2, :day))

    assert {:ok, %{events: 2, evidence: 1}} = Retention.prune(now: @now)
    assert {:error, :evidence_expired} = Evidence.fetch(bundle.id, "event:#{failure.id}")

    assert %Evidence.Bundle{digest: digest, expired_at: @now, payload: nil} =
             Repo.get!(Evidence.Bundle, bundle.id)

    assert digest == bundle.digest

    for record <- [success, failure] do
      assert %Events.Event{body: %{"quality" => %{"evidence_expired" => true}} = body} =
               Repo.get!(Events.Event, record.id)

      assert body["event_id"] == record.event_id
      refute Map.has_key?(body, "evidence")
    end

    for record <- [young, pending] do
      assert %Events.Event{body: %{"evidence" => _}} = Repo.get!(Events.Event, record.id)
    end

    assert %{"receipts" => [%{"status" => "duplicate"}, %{"status" => "duplicate"}]} =
             Events.ingest(host_id, "resubmit", [active_item, sealed_item])

    assert Repo.aggregate(Events.Event, :count, :id) == 4
    assert %Outbox.Entry{} = Repo.get!(Outbox.Entry, pending.id)
    assert {:ok, %{events: 0, evidence: 0}} = Retention.prune(now: @now)
  end

  test "a tighter live TTL hides and removes earlier frozen copies", %{host_id: host_id} do
    {record, _item} = event(host_id, 1, "active", "handled_error", "failure", 20)

    issue = create_issue()
    snapshot = %{id: issue.id, events: [record]}
    assert {:ok, report} = Reports.refresh(snapshot, now: @now)
    bundle_id = report.evidence_bundle_id
    assert {:ok, %Evidence.Bundle{expires_at: old_expiry}} = Evidence.load(bundle_id, @now)
    assert DateTime.after?(old_expiry, @now)

    original_ttl = :ets.lookup(:backplane_settings, @ttl_key)

    on_exit(fn ->
      case original_ttl do
        [] -> :ets.delete(:backplane_settings, @ttl_key)
        [row] -> :ets.insert(:backplane_settings, row)
      end
    end)

    :ets.insert(:backplane_settings, {@ttl_key, 14})

    assert {:error, :evidence_expired} = Evidence.load(bundle_id, @now)
    assert %Evidence.Bundle{payload: payload} = Repo.get!(Evidence.Bundle, bundle_id)
    assert is_map(payload)

    assert {:ok, %{events: 0, evidence: 1}} = Retention.prune(now: @now)
    assert %Outbox.Entry{} = Repo.get!(Outbox.Entry, record.id)
    assert %Evidence.Bundle{payload: nil} = Repo.get!(Evidence.Bundle, bundle_id)
    assert {:error, :evidence_expired} = Queries.get_evidence(bundle_id, "event:#{record.id}")

    assert {:ok, _} = Reports.refresh(snapshot, now: @now, revision: 2, change: :repeat)

    assert {:ok, %{"body" => %{"quality" => %{"evidence_expired" => true}}}} =
             Queries.get_report(issue.id)
  end

  test "the retention worker prunes on startup and continues on its own timer",
       %{host_id: host_id} do
    {first, _} = event(host_id, 1, "active", "handled_error", "failure", 40)
    Repo.delete!(Repo.get!(Outbox.Entry, first.id))
    start_supervised!({Retention.Worker, interval_ms: 20, now: @now})
    assert expired_event?(first.id)

    {later, _} = event(host_id, 2, "active", "handled_error", "failure", 40)
    Repo.delete!(Repo.get!(Outbox.Entry, later.id))
    assert expired_event?(later.id)
  end

  test "evidence and report queries only expose redacted structured details and omit attachments",
       %{host_id: host_id} do
    token = "diagnostics-synthetic-fake-token"
    attachment = "diagnostics-private-attachment-bytes"

    details = %{
      "exception" => %{"message" => "Authorization: Bearer " <> token},
      "references" => ["attachment:operator-local"]
    }

    {record, item} = event(host_id, 1, "active", "handled_error", "failure", 1, details)
    raw = put_in(item["event"], ["evidence", "attachments"], [%{"content" => attachment}])
    assert {:error, :invalid_event} = Envelope.seal(raw)

    # Exercise evidence projection even for a stored record predating the ingest redactor.
    stored_with_attachment = put_in(record.body, ["evidence"], raw["evidence"])
    record = Repo.update!(Ecto.Changeset.change(record, body: stored_with_attachment))
    issue = create_issue()
    snapshot = %{id: issue.id, events: [record], summary: "Cookie: session=" <> token}
    assert {:ok, report} = Reports.refresh(snapshot, now: @now)
    assert {:ok, evidence} = Queries.get_evidence(report.evidence_bundle_id, "event:#{record.id}")
    assert {:ok, summary} = Queries.get_report(issue.id)

    assert get_in(evidence, ["exception", "message"]) == "[REDACTED]"
    assert get_in(summary, ["body", "summary"]) == "[REDACTED]"

    assert {:error, :not_found} =
             Queries.get_evidence(report.evidence_bundle_id, "attachment:operator-local")

    for response <- [evidence, summary] do
      bytes = JSON.encode!(response)
      refute bytes =~ token
      refute bytes =~ attachment
      refute bytes =~ "attachments"
    end
  end

  defp expired_event?(id, remaining \\ 40) do
    expired = get_in(Repo.get!(Events.Event, id).body, ["quality", "evidence_expired"]) == true

    if expired or remaining == 0 do
      expired
    else
      Process.sleep(15)
      expired_event?(id, remaining - 1)
    end
  end

  defp create_issue do
    Repo.insert!(%Issues.Issue{
      fingerprint: "retention-test",
      fingerprint_version: 1,
      category: "software_defect",
      severity: "high",
      first_seen_at: @now,
      last_seen_at: @now
    })
  end

  defp event(
         host_id,
         seq,
         epoch,
         type,
         outcome,
         age,
         details \\ %{"exception" => %{"message" => "Retained observation"}}
       ) do
    id = "event-#{seq}"
    received_at = DateTime.add(@now, -age, :day)

    body = %{
      "application" => "test",
      "source_id" => "retention-source",
      "event_type" => type,
      "event_id" => id,
      "producer_epoch" => epoch,
      "source_sequence" => seq,
      "occurred_at" => DateTime.to_iso8601(received_at),
      "schema_version" => 1,
      "result" => %{"outcome" => outcome},
      "quality" => %{"redaction_policy_version" => 1},
      "evidence" => details
    }

    {:ok, _, digest} = Envelope.seal(body)
    item = Receipt.entry(body, digest)
    assert %{"receipts" => [%{"status" => "stored"}]} = Events.ingest(host_id, "first", [item])
    event = Repo.get_by!(Events.Event, source_id: "retention-source", event_id: id)
    {Repo.update!(Ecto.Changeset.change(event, received_at: received_at)), item}
  end
end
