defmodule Backplane.DiagnosticsClient.ReporterTest do
  use ExUnit.Case, async: false

  alias Backplane.DiagnosticsClient.{Context, Receipt, Reporter}

  @name Backplane.DiagnosticsClient.TestReporter

  test "admission is bounded while transport blocks, and matching local receipts release capacity" do
    parent = self()

    reporter =
      start_supervised!(
        {Reporter,
         [
           name: @name,
           source_id: "source",
           application: "app",
           interval_ms: 60_000,
           max_events: 2,
           send_batch: fn batch ->
             send(parent, {:batch, self(), batch})
             receive do: ({:reply, response} -> response)
           end
         ]}
      )

    attrs = %{
      "event_type" => "exception",
      "evidence" => %{"exception" => %{"message" => "Bearer synthetic-fixture"}}
    }

    assert :enqueued =
             Context.with_context(%{"subject" => %{"run_id" => "run-a"}}, fn ->
               Reporter.report(attrs, @name)
             end)

    assert :enqueued = Reporter.report(attrs, @name)
    assert {:error, :queue_full} = Reporter.report(attrs, @name)
    assert %{pending: 2, dropped: 1} = Reporter.health(@name)
    send(reporter, :flush)

    assert_receive {:batch, sender, %{"batch_id" => batch, "events" => [first, second]}}, 1_000
    assert get_in(first, ["event", "subject", "run_id"]) == "run-a"
    refute Map.has_key?(second["event"], "subject")
    assert get_in(first, ["event", "evidence", "exception", "message"]) == "[REDACTED]"

    response =
      Receipt.response(:local, batch, [
        Receipt.result(first, "stored"),
        Receipt.result(first, "identity_conflict"),
        Receipt.result(second, "stored")
      ])

    send(sender, {:reply, {:ok, response}})

    assert %{pending: 1, transport: :invalid_receipt, last_confirmed_at_ms: time} =
             wait_for_pending(1)

    assert is_integer(time)
  end

  test "keeps immutable event bytes across Host failure and retry" do
    parent = self()

    start_supervised!(
      {Reporter,
       [
         name: @name,
         source_id: "source",
         application: "app",
         interval_ms: 10,
         send_batch: fn batch ->
           send(parent, {:batch, self(), batch})
           receive do: ({:reply, response} -> response)
         end
       ]}
    )

    assert :enqueued = Reporter.report(%{"event_type" => "handled_error"}, @name)
    assert_receive {:batch, sender, %{"batch_id" => original_batch, "events" => [original]}}, 500
    send(sender, {:reply, {:error, :host_unavailable}})
    assert_receive {:batch, retry, %{"batch_id" => retry_batch, "events" => [^original]}}, 2_500
    refute original_batch == retry_batch

    send(
      retry,
      {:reply,
       {:ok, Receipt.response(:local, retry_batch, [Receipt.result(original, "duplicate")])}}
    )

    assert %{pending: 0, pending_bytes: 0, transport: :available} = wait_for_pending(0)
  end

  defp wait_for_pending(count, attempts \\ 100)

  defp wait_for_pending(count, attempts) do
    case Reporter.health(@name) do
      %{pending: ^count} = health ->
        health

      health when attempts == 0 ->
        health

      _ ->
        Process.sleep(5)
        wait_for_pending(count, attempts - 1)
    end
  end
end
