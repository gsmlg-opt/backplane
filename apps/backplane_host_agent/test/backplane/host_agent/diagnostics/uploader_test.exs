defmodule Backplane.HostAgent.Diagnostics.UploaderTest do
  use ExUnit.Case, async: true

  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.HostAgent.Diagnostics.{Spool, Uploader}

  @moduletag :tmp_dir
  @source %{id: "test-source", application: "test"}

  def push(_channel, "diagnostics_sync", batch, _timeout), do: Process.get(__MODULE__).(batch)

  defmodule LegacyGateway do
    def push(_channel, "diagnostics_capabilities", %{}, _timeout) do
      {:error, %{"code" => "unsupported_protocol", "retryable" => false}}
    end
  end

  test "commits only unique matching remote successes from a complete response", %{tmp_dir: dir} do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))
    entries = Enum.map(1..2, &entry/1)

    assert %{"receipts" => [%{"status" => "stored"}, %{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", entries)

    Process.put(__MODULE__, fn %{"batch_id" => batch, "events" => [first, second]} ->
      {:ok,
       Receipt.response(:remote, batch, [
         Receipt.result(first, "stored"),
         Receipt.result(second, "stored"),
         Receipt.result(first, "identity_conflict")
       ])}
    end)

    assert {:ok, :invalid_receipt} =
             Uploader.drain_once(spool, __MODULE__, self(), {100, 524_288})

    assert {:ok, [%{"state" => "confirmed", "bytes" => 0}, %{"state" => "pending", "count" => 1}]} =
             Spool.health(spool)
  end

  test "retains offered events when authorization fails after negotiation", %{tmp_dir: dir} do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", [entry(1)])

    Process.put(__MODULE__, fn _batch -> {:error, %{"code" => "unauthorized"}} end)

    assert {:error, :unauthorized} =
             Uploader.drain_once(spool, __MODULE__, self(), {100, 524_288})

    assert {:ok, [%{"state" => "pending", "count" => 1, "bytes" => bytes}]} = Spool.health(spool)
    assert bytes > 0
  end

  test "preserves queued events when a legacy gateway has no diagnostics capability", %{
    tmp_dir: dir
  } do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))
    channel = self()

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", [entry(1)])

    uploader =
      start_supervised!(
        {Uploader,
         spool: spool,
         interval_ms: 60_000,
         channel_module: LegacyGateway,
         channel_provider: fn -> channel end}
      )

    send(uploader, :drain)
    assert Uploader.status(uploader) == :unsupported_capability
    assert {:ok, [%{"state" => "pending", "count" => 1}]} = Spool.health(spool)
  end

  test "dead-letters a rejected event and confirms the other member of the same batch", %{
    tmp_dir: dir
  } do
    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))

    assert %{"receipts" => [%{"status" => "stored"}, %{"status" => "stored"}]} =
             Spool.ingest(spool, @source, "batch", [entry(1), entry(2)])

    Process.put(__MODULE__, fn %{"batch_id" => batch, "events" => [one, two]} ->
      {:ok,
       Receipt.response(:remote, batch, [
         Receipt.result(one, "permanent_rejection", :unauthorized_source),
         Receipt.result(two, "stored")
       ])}
    end)

    assert {:ok, :connected} = Uploader.drain_once(spool, __MODULE__, self(), {100, 524_288})

    assert {:ok, [%{"event_id" => "event-1", "reason" => "unauthorized_source"}]} =
             Spool.dead_letters(spool, @source.id)

    assert {:ok, :ok} = Spool.requeue(spool, @source.id, "event-1")

    assert {:ok, [%{"event_id" => "event-1", "forward_digest" => digest}]} =
             Spool.ready(spool, 10)

    assert digest == entry(1)["digest"]
  end

  defp entry(seq) do
    event = %{
      "schema_version" => 1,
      "event_type" => "exception",
      "event_id" => "event-#{seq}",
      "source_id" => @source.id,
      "application" => @source.application,
      "producer_epoch" => "boot",
      "source_sequence" => seq,
      "occurred_at" => "2026-11-28T03:04:05Z",
      "quality" => %{"redaction_policy_version" => 1}
    }

    {:ok, _, digest} = Envelope.seal(event)
    Receipt.entry(event, digest)
  end
end
