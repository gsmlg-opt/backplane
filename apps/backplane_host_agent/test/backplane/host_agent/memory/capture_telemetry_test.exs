defmodule Backplane.HostAgent.Memory.CaptureTelemetryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{CaptureUploader, EventEnvelope}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir
  @prefix [:backplane, :host_agent, :memory, :capture]
  @rejected_event @prefix ++ [:rejected]

  defmodule Channel do
    def push(_channel, "memory_events", payload) do
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [%{"event_id" => "event", "status" => "accepted"}]
       }}
    end
  end

  setup do
    handler = "capture-telemetry-#{System.unique_integer([:positive])}"
    events = Enum.map(~w(captured rejected spool connection upload ack)a, &(@prefix ++ [&1]))
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def handle_event(event, measurements, metadata, owner) do
    send(owner, {:capture_telemetry, event, measurements, metadata})
  end

  test "capture lifecycle emits numeric metrics without event content", %{tmp_dir: dir} do
    spool =
      start_supervised!(
        {Spool,
         database: Path.join(dir, "telemetry.db"),
         name: nil,
         id: {:telemetry_spool, System.unique_integer([:positive])}}
      )

    assert {:ok, _} = Spool.append(spool, event(%{"password" => "never-leak"}))
    assert _stats = Spool.stats(spool)

    assert {:ok, %{"acknowledged" => 1}} =
             CaptureUploader.drain_once(
               spool: spool,
               channel: self(),
               channel_module: Channel,
               host_id: "host"
             )

    messages = collect_events(5, [])
    names = Enum.map(messages, fn {event, _, _} -> List.last(event) end)
    assert :captured in names
    assert :spool in names
    assert :connection in names
    assert :upload in names
    assert :ack in names

    assert Enum.all?(messages, fn {_event, measurements, metadata} ->
             numeric_measurements?(measurements) and not leaks_content?(metadata)
           end)
  end

  test "rejection telemetry contains only count and permanence", %{tmp_dir: dir} do
    spool =
      start_supervised!(
        {Spool,
         database: Path.join(dir, "reject.db"),
         name: nil,
         id: {:reject_spool, System.unique_integer([:positive])}}
      )

    assert {:ok, _} = Spool.append(spool, event(%{"message" => "private evidence"}))
    assert :ok = Spool.reject(spool, "event", "contains private evidence", true)

    assert_receive {:capture_telemetry, @rejected_event, %{count: 1}, %{permanent: true}}
  end

  defp collect_events(0, events), do: Enum.reverse(events)

  defp collect_events(remaining, events) do
    receive do
      {:capture_telemetry, event, measurements, metadata} ->
        collect_events(remaining - 1, [{event, measurements, metadata} | events])
    after
      1_000 -> flunk("missing capture telemetry event")
    end
  end

  defp numeric_measurements?(measurements) do
    Enum.all?(measurements, fn {_key, value} -> is_number(value) end)
  end

  defp leaks_content?(metadata) do
    encoded = inspect(metadata)
    encoded =~ "never-leak" or encoded =~ "private evidence" or encoded =~ "payload"
  end

  defp event(payload) do
    %{
      schema_version: 1,
      event_id: "event",
      idempotency_key: "idem-event",
      integration: "codex",
      host_id: "host",
      agent_id: "agent",
      event_type: "agent.prompt.submitted",
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      session_id: "session",
      payload: payload,
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: %{}
    }
  end
end
