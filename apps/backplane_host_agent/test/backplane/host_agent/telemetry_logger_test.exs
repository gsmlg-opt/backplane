defmodule Backplane.HostAgent.TelemetryLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.HostAgent.TelemetryLogger

  setup do
    logger_level = Logger.level()

    on_exit(fn ->
      TelemetryLogger.detach()
      Logger.configure(level: logger_level)
    end)
  end

  test "attach logs host-agent memory telemetry events" do
    log =
      capture_log([level: :debug], fn ->
        Logger.configure(level: :debug)
        assert :ok = TelemetryLogger.attach()

        :telemetry.execute(
          [:backplane, :host_agent, :memory, :call, :stop],
          %{duration: System.convert_time_unit(12, :millisecond, :native)},
          %{
            agent_id: "hermes",
            argument_keys: ["scope"],
            method: "list",
            result: :ok
          }
        )

        Logger.flush()
      end)

    assert log =~ "Host agent memory call completed"
    assert log =~ "method=list"
    assert log =~ "agent_id=hermes"
    assert log =~ "result=ok"
  end
end
