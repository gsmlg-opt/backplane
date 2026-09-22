defmodule Backplane.HostAgent.Memory.Edge.TelemetryTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.Edge.Telemetry

  test "events contain only bounded measurements and enumerated metadata" do
    id = "edge-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      Telemetry.events(),
      fn event, measurements, metadata, pid ->
        send(pid, {event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    Telemetry.state(%{
      items: 3,
      bytes: 40,
      revision: 7,
      lag: 2,
      stale_age_seconds: 5,
      retry_count: 1,
      dead_letter_count: 2,
      protection_mode: :plaintext_development
    })

    Telemetry.delivery(:snapshot, :ok)
    Telemetry.failure(:integrity)
    Telemetry.eviction(%{expired: 1, evicted: 2})

    for _ <- 1..4 do
      assert_receive {event, measurements, metadata}
      assert event in Telemetry.events()
      assert Enum.all?(measurements, fn {_key, value} -> is_number(value) end)
      refute inspect(metadata) =~ "secret content"
      refute Map.has_key?(metadata, :content)
    end

    Telemetry.state(%{items: 1, lag: nil, protection_mode: :plaintext_development})
    assert_receive {_, measurements, %{lag_status: :unavailable}}
    assert measurements.items == 1
    refute Map.has_key?(measurements, :lag)
  end
end
