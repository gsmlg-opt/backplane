defmodule Backplane.HostAgent.Diagnostics.SpoolTest do
  use ExUnit.Case, async: true

  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Redaction}
  alias Backplane.HostAgent.Diagnostics.Spool

  @moduletag :tmp_dir
  @source %{id: "source-a", application: "test", critical: true}

  test "retains the first forward bytes through a policy upgrade and restart", %{tmp_dir: dir} do
    path = Path.join(dir, "events.db")
    {:ok, spool} = Spool.start_link(path: path, redact: &policy(&1, 2))
    item = entry(@source, 1)

    assert %{"level" => "local_durable", "receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", [item])

    assert {:ok, [original]} = Spool.ready(spool, 100)
    assert original["forward_digest"] != item["digest"]
    assert {:error, :delivery_pending} = Spool.seal_epoch(spool, @source.id, "boot")
    GenServer.stop(spool)

    {:ok, spool} = Spool.start_link(path: path, redact: &policy(&1, 3))

    assert %{"receipts" => [%{"status" => "duplicate"}]} =
             Spool.ingest(spool, @source, "retry", [item])

    assert {:ok, [^original]} = Spool.ready(spool, 100)

    assert {:ok, :ok} =
             Spool.settle(spool, @source.id, [
               {"event-1", original["forward_digest"], {:ack, "stored"}}
             ])

    assert {:ok, :ok} = Spool.seal_epoch(spool, @source.id, "boot")
    GenServer.stop(spool)

    {:ok, spool} = Spool.start_link(path: path)
    assert {:ok, []} = Spool.ready(spool, 100)
    assert {:ok, [%{"state" => "confirmed", "bytes" => 0}]} = Spool.health(spool)

    assert %{"receipts" => [%{"status" => "duplicate"}]} =
             Spool.ingest(spool, @source, "repeat", [item])

    assert %{"receipts" => [%{"reason" => "epoch_sealed"}]} =
             Spool.ingest(spool, @source, "repeat", [entry(@source, 2)])
  end

  test "preserves identities on conflicting IDs and sequences without blocking a good item", %{
    tmp_dir: dir
  } do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))
    item = entry(@source, 1)
    conflict = entry(@source, 2, %{"event_id" => "event-1"})
    sequence_conflict = entry(@source, 1, %{"event_id" => "new"})

    assert %{
             "receipts" => [
               %{"status" => "stored"},
               %{"reason" => "identity_conflict"},
               %{"reason" => "source_sequence_conflict"},
               %{"status" => "stored"}
             ]
           } =
             Spool.ingest(spool, @source, "batch", [
               item,
               conflict,
               sequence_conflict,
               entry(@source, 2)
             ])
  end

  test "a storage write failure never returns a durable acknowledgement", %{tmp_dir: dir} do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))
    %{db: db} = :sys.get_state(spool)
    {:ok, _} = Turso.query(db, "PRAGMA query_only = 1")
    item = entry(@source, 1)

    assert %{
             "receipts" => [
               %{"status" => "retryable_rejection", "reason" => "persistence_unavailable"}
             ]
           } =
             Spool.ingest(spool, @source, "failed", [item])

    assert {:ok, []} = Spool.health(spool)
    {:ok, _} = Turso.query(db, "PRAGMA query_only = 0")

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "restored", [item])
  end

  test "enforces the ordinary reserve and per-source budgets during concurrent insertion", %{
    tmp_dir: dir
  } do
    second = %{@source | id: "source-b"}
    third = %{@source | id: "source-c"}
    size = size(entry(@source, 1))

    {:ok, spool} =
      Spool.start_link(
        path: Path.join(dir, "events.db"),
        max_bytes: 4 * size,
        source_max_bytes: 2 * size
      )

    receipts =
      for {source, seq} <- [
            {@source, 1},
            {@source, 2},
            {second, 1},
            {second, 2},
            {third, 1},
            {third, 2}
          ] do
        Task.async(fn -> Spool.ingest(spool, source, "batch", [entry(source, seq)]) end)
      end
      |> Task.await_many()
      |> Enum.flat_map(& &1["receipts"])

    assert Enum.count(receipts, &(&1["status"] == "stored")) == 3
    assert Enum.count(receipts, &(&1["reason"] == "quota_exceeded")) == 3
    assert {:ok, [%{"state" => "pending", "count" => 3}]} = Spool.health(spool)

    fourth = %{@source | id: "source-d"}
    urgent = entry(fourth, 1, %{"event_type" => "exception"})

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, fourth, "priority", [urgent])

    assert %{"receipts" => [%{"reason" => "quota_exceeded"}]} =
             Spool.ingest(spool, fourth, "full", [
               entry(fourth, 2, %{"event_type" => "exception"})
             ])
  end

  test "expires pending data visibly and prunes retired bodies over ten percent of quota", %{
    tmp_dir: dir
  } do
    now = :atomics.new(1, [])
    :atomics.put(now, 1, 100)
    item = entry(@source, 1)

    {:ok, spool} =
      Spool.start_link(
        path: Path.join(dir, "events.db"),
        max_bytes: size(item) * 3,
        max_age_seconds: 10,
        clock: fn -> :atomics.get(now, 1) end
      )

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", [item])

    :atomics.put(now, 1, 111)
    assert {:ok, :ok} = Spool.maintain(spool)
    assert {:ok, [%{"state" => "expired", "count" => 1, "bytes" => 0}]} = Spool.health(spool)
    assert {:ok, []} = Spool.ready(spool, 100)

    assert %{"receipts" => [%{"status" => "permanent_rejection", "reason" => "expired"}]} =
             Spool.ingest(spool, @source, "retry", [item])
  end

  defp entry(source, seq, overrides \\ %{}) do
    event =
      Map.merge(
        %{
          "schema_version" => 1,
          "event_type" => "run_progress",
          "event_id" => "event-#{seq}",
          "source_id" => source.id,
          "application" => source.application,
          "producer_epoch" => "boot",
          "source_sequence" => seq,
          "occurred_at" => "2026-11-28T03:04:05Z",
          "quality" => %{"redaction_policy_version" => 1}
        },
        overrides
      )

    {:ok, _, digest} = Envelope.seal(event)
    Receipt.entry(event, digest)
  end

  defp policy(event, version),
    do: put_in(Redaction.project(event), ["quality", "redaction_policy_version"], version)

  defp size(%{"event" => event}) do
    {:ok, bytes, _} = Envelope.seal(event)
    byte_size(bytes)
  end
end
