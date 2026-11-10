defmodule Backplane.Memory.Workers.HostSnapshotWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import ExUnit.CaptureLog
  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Ingest, Records}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp snapshot_event(host, payload, key \\ nil) do
    occurred_at = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host,
      "agent_id" => "host-collector",
      "client_id" => "host_collector",
      "integration" => "host_collector",
      "event_type" => "host.snapshot.collected",
      "occurred_at" => occurred_at,
      "idempotency_key" => key || unique("host_collector:launchd"),
      "payload" => payload
    })
    |> Map.delete("session_id")
    |> Map.delete("sequence")
  end

  defp ingest(host, events) do
    assert {:ok, %{"results" => results}} =
             Ingest.ingest_batch(ingest_auth_context(host), %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => host,
               "events" => events
             })

    results
  end

  defp launchd_payload(labels) do
    %{
      "collector" => "launchd",
      "unit" => "local",
      "complete" => true,
      "items" => Enum.map(labels, &%{"label" => &1})
    }
  end

  defp host_facts(host),
    do: Enum.filter(Records.list(%{"host_id" => host}), &(&1.writer == "host_collector"))

  test "accepted snapshot is applied by the worker as host_collector facts" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host = unique("snap-host")
      event = snapshot_event(host, launchd_payload(["com.example.a"]))

      assert [%{"status" => "accepted"}] = ingest(host, [event])
      assert host_facts(host) == []

      assert %{success: successes, failure: 0} = Styx.drain_queue(queue: :memory)
      assert successes >= 1

      assert [%{property: "launchd_job", content: content}] = host_facts(host)
      assert content =~ "com.example.a"
    end)
  end

  test "a duplicate upload is reported duplicate and enqueues nothing new" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host = unique("dup-host")
      key = unique("host_collector:launchd:local")
      event = snapshot_event(host, launchd_payload(["com.example.a"]), key)

      assert [%{"status" => "accepted"}] = ingest(host, [event])
      Styx.drain_queue(queue: :memory)

      assert [%{"status" => "duplicate"}] = ingest(host, [event])
      assert %{success: 0, failure: 0} = Styx.drain_queue(queue: :memory)
      assert [_one] = host_facts(host)
    end)
  end

  test "an invalid payload cancels the job, logs a warning and writes no records" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host = unique("bad-host")
      event = snapshot_event(host, %{"collector" => "nope", "unit" => "local"})

      assert [%{"status" => "accepted"}] = ingest(host, [event])

      log = capture_log(fn -> Styx.drain_queue(queue: :memory) end)

      assert log =~ "unknown_collector"
      assert host_facts(host) == []
    end)
  end

  test "a single-event append also enqueues the worker" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host = unique("single-host")

      assert {:ok, _event} =
               Backplane.Memory.Events.Store.append(%{
                 stream_id: "host_collector:#{host}",
                 event_type: "host.snapshot.collected",
                 host_id: host,
                 agent_id: "host-collector",
                 integration: "host_collector",
                 payload: launchd_payload(["com.example.single"]),
                 occurred_at: DateTime.add(DateTime.utc_now(), -60)
               })

      assert %{success: 1, failure: 0} = Styx.drain_queue(queue: :memory)
      assert [%{property: "launchd_job"}] = host_facts(host)
    end)
  end

  test "perform/1 ignores a missing event" do
    assert :ok =
             Backplane.Memory.Workers.HostSnapshotWorker.perform(%Styx.Job{
               args: %{"event_id" => Ecto.UUID.generate()}
             })

  end
end
