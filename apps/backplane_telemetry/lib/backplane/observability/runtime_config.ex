defmodule Backplane.Observability.RuntimeConfig do
  @moduledoc false

  @legacy_module BackplaneTelemetry.TelemetryLogger
  @runtime_module Backplane.Observability.RuntimeSink

  @doc "Returns runtime sink options, mapping legacy TelemetryLogger config when needed."
  @spec runtime_sink_opts(keyword()) :: keyword()
  def runtime_sink_opts(extra \\ []) do
    legacy = Application.get_env(:backplane_telemetry, @legacy_module, [])
    runtime = Application.get_env(:backplane_telemetry, @runtime_module, [])

    [
      log_to_logger:
        Keyword.get(extra, :log_to_logger,
          Keyword.get(runtime, :log_to_logger, Keyword.get(legacy, :log_to_logger, true))
        ),
      log_to_console:
        Keyword.get(extra, :log_to_console,
          Keyword.get(runtime, :log_to_console, Keyword.get(legacy, :log_to_console, false))
        ),
      log_to_file:
        Keyword.get(extra, :log_to_file,
          Keyword.get(runtime, :log_to_file, Keyword.get(legacy, :log_to_file))
        )
    ]
  end
end
