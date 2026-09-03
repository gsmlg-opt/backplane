defmodule Backplane.Observability.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Backplane.Observability.RuntimeConfig

  setup do
    previous_legacy =
      Application.get_env(:backplane_telemetry, BackplaneTelemetry.TelemetryLogger)

    previous_runtime =
      Application.get_env(:backplane_telemetry, Backplane.Observability.RuntimeSink)

    on_exit(fn ->
      Application.put_env(:backplane_telemetry, BackplaneTelemetry.TelemetryLogger, previous_legacy)
      Application.put_env(:backplane_telemetry, Backplane.Observability.RuntimeSink, previous_runtime)
    end)

    :ok
  end

  test "maps legacy TelemetryLogger config to runtime sink options" do
    Application.put_env(:backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
      log_to_logger: false,
      log_to_console: true,
      log_to_file: "/tmp/legacy.jsonl"
    )

    Application.put_env(:backplane_telemetry, Backplane.Observability.RuntimeSink, [])

    assert RuntimeConfig.runtime_sink_opts() == [
             log_to_logger: false,
             log_to_console: true,
             log_to_file: "/tmp/legacy.jsonl"
           ]
  end

  test "runtime sink config overrides legacy mapping" do
    Application.put_env(:backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
      log_to_logger: false,
      log_to_console: false,
      log_to_file: "/tmp/legacy.jsonl"
    )

    Application.put_env(:backplane_telemetry, Backplane.Observability.RuntimeSink,
      log_to_logger: true,
      log_to_console: true,
      log_to_file: "/tmp/runtime.jsonl"
    )

    assert RuntimeConfig.runtime_sink_opts() == [
             log_to_logger: true,
             log_to_console: true,
             log_to_file: "/tmp/runtime.jsonl"
           ]
  end
end
