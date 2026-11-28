defmodule Backplane.Diagnostics.EventsTest do
  use ExUnit.Case, async: true

  alias Backplane.Diagnostics.{Events, Outbox, Projector, Resolutions, Sources}
  alias Backplane.DiagnosticsClient.{Canonical, Receipt}
  alias Backplane.Repo

  @fixture Path.expand("../../../docs/diagnostics/protocol/v1/event.json", __DIR__)

  setup tags do
    BackplaneDataCase.setup_sandbox(Repo, tags)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO skill_hosts (name, inserted_at, updated_at)
        VALUES ($1, NOW(), NOW()) RETURNING id
        """,
        ["diagnostics-host-#{System.unique_integer([:positive])}"]
      )

    host_id = Ecto.UUID.load!(id)
    event = @fixture |> File.read!() |> Formata.JSON.decode!()

    assert {:ok, _source} =
             Sources.register(host_id, %{
               id: event["source_id"],
               application: event["application"],
               repository: get_in(event, ["version", "repository"]),
               service_instance: event["service_instance"]
             })

    %{host_id: host_id, event: event}
  end

  test "commits one event and outbox then returns a durable duplicate after ACK loss", %{
    host_id: host_id,
    event: event
  } do
    event =
      put_in(event, ["evidence", "exception", "message"], "Authorization: Bearer fixture-secret")

    item = entry(event)

    assert %{"level" => "remote_durable", "receipts" => [%{"status" => "stored"}]} =
             Events.ingest(host_id, "first", [item])

    assert %{"receipts" => [%{"status" => "duplicate"}]} = Events.ingest(host_id, "retry", [item])
    assert [%Events.Event{id: id, body: body}] = Repo.all(Events.Event)
    assert get_in(body, ["evidence", "exception", "message"]) == "[REDACTED]"
    assert %Outbox.Entry{} = Repo.get!(Outbox.Entry, id)
    assert Outbox.health().pending == 1
  end

  test "rejects invalid items independently, preserving conflicting IDs and sequences", %{
    host_id: host_id,
    event: event
  } do
    bad_version = entry(%{event | "schema_version" => 2})
    different_content = entry(%{event | "duration_us" => 211})
    same_sequence = entry(%{event | "event_id" => "other"})
    next_epoch = entry(%{event | "event_id" => "restart", "producer_epoch" => "next-boot"})

    assert %{"receipts" => receipts} =
             Events.ingest(host_id, "batch", [
               bad_version,
               entry(event),
               different_content,
               same_sequence,
               next_epoch
             ])

    assert [
             %{"status" => "unsupported_schema"},
             %{"status" => "stored"},
             %{"status" => "identity_conflict", "reason" => "identity_conflict"},
             %{"status" => "identity_conflict", "reason" => "source_sequence_conflict"},
             %{"status" => "stored"}
           ] = receipts

    assert Outbox.health().pending == 2
  end

  test "checks authentication-derived source and registered metadata", %{
    host_id: host_id,
    event: event
  } do
    assert %{"receipts" => [%{"reason" => "unauthorized_source"}]} =
             Events.ingest(Ecto.UUID.generate(), "other-host", [entry(event)])

    spoof = %{event | "service_instance" => "impostor"}

    assert %{"receipts" => [%{"reason" => "unauthorized_source"}]} =
             Events.ingest(host_id, "unauthorized", [entry(spoof)])

    assert [] == Repo.all(Events.Event)
    assert Outbox.health().pending == 0
  end

  test "retains identity after body reclamation and closes sealed epochs", %{
    host_id: host_id,
    event: event
  } do
    source_id = event["source_id"]
    epoch = event["producer_epoch"]
    item = entry(event)
    assert %{"receipts" => [%{"status" => "stored"}]} = Events.ingest(host_id, "original", [item])
    assert {:error, :projection_pending} = Events.seal_epoch(host_id, source_id, epoch)

    Repo.delete_all(Outbox.Entry)
    Repo.delete_all(Events.Event)
    assert {:ok, %Events.Epoch{}} = Events.seal_epoch(host_id, source_id, epoch)

    assert %{"receipts" => [%{"status" => "duplicate"}]} =
             Events.ingest(host_id, "duplicate", [item])

    assert %{"receipts" => [%{"reason" => "epoch_sealed"}]} =
             Events.ingest(host_id, "sealed", [entry(%{event | "event_id" => "new-id"})])

    assert [] == Repo.all(Events.Event)
  end

  test "operator history imports from sealed epochs without changing active projections", %{
    host_id: host_id,
    event: event
  } do
    item = entry(event)

    assert {:error, :epoch_not_sealed} = Events.import_history(host_id, item, "operator")
    assert {:ok, _} = Events.seal_epoch(host_id, event["source_id"], event["producer_epoch"])

    assert %{"receipts" => [%{"reason" => "epoch_sealed"}]} =
             Events.ingest(host_id, "live", [item])

    assert {:ok, "stored"} = Events.import_history(host_id, item, "operator")
    assert {:ok, "duplicate"} = Events.import_history(host_id, item, "operator")
    assert %Events.Event{id: key, historical: true} = Repo.one!(Events.Event)
    assert Outbox.health().pending == 0
    assert {:ok, :historical} = Projector.project(key)
    assert Repo.aggregate(Projector.Claim, :count) == 0

    assert %{actor: "operator", action: "history_imported", entity_id: ^key} =
             Repo.one!(Resolutions.ManagementAction)
  end

  defp entry(event) do
    {:ok, bytes} = Canonical.encode(event)
    Receipt.entry(event, Canonical.digest(bytes))
  end
end
