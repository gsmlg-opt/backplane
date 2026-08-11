defmodule Backplane.McpProtocol.TelemetryTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Telemetry

  @redacted "[REDACTED]"

  test "execute preserves measurements and sanitizes metadata before telemetry handlers see it" do
    handler = {__MODULE__, make_ref()}
    event = [:backplane_mcp_protocol, :redaction_test]
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn received_event, measurements, metadata, pid ->
          send(pid, {:telemetry, received_event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    measurement_ref = make_ref()
    measurements = %{duration: 42, native: measurement_ref}

    metadata = %{
      method: "tools/call",
      access_token: "telemetry-secret",
      token: "telemetry-token-secret",
      request: %{"Authorization" => "Bearer nested-secret"},
      note: ["Bearer ", "split-telemetry-secret"],
      char_keyed: %{~c"token" => "char-key-secret"}
    }

    assert :ok = Telemetry.execute([:redaction_test], measurements, metadata)

    assert_receive {:telemetry, ^event, ^measurements,
                    %{
                      method: "tools/call",
                      access_token: @redacted,
                      token: @redacted,
                      request: %{"Authorization" => @redacted},
                      note: "Bearer [REDACTED]",
                      char_keyed: %{~c"token" => @redacted}
                    }}
  end
end
