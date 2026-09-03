defmodule Backplane.Observability.RuntimeSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.Observability.RuntimeSink

  setup do
    prev_level = Logger.level()
    Logger.configure(level: :info)

    temp_dir = System.tmp_dir!()
    log_file = Path.join(temp_dir, "runtime_sink_#{System.unique_integer([:positive])}.jsonl")

    Application.put_env(:backplane_telemetry, RuntimeSink,
      log_to_logger: true,
      log_to_console: false,
      log_to_file: log_file
    )

    start_supervised!({RuntimeSink, [log_to_file: log_file]})

    on_exit(fn ->
      File.rm(log_file)
      Logger.configure(level: prev_level)
    end)

    %{log_file: log_file}
  end

  test "formats legacy telemetry events through the runtime sink", %{log_file: log_file} do
    log =
      capture_log(fn ->
        :telemetry.execute(
          [:backplane, :mcp_request, :start],
          %{system_time: System.system_time()},
          %{method: "tools/list", request_id: "req-1", trace_id: "trace-1"}
        )

        :sys.get_state(RuntimeSink)
        Process.sleep(20)
      end)

    assert log =~ "Observability mcp_proxy request start"
    assert File.exists?(log_file)
    assert File.read!(log_file) =~ "tools/list"
  end

  test "passes through v2 domain telemetry envelopes", %{log_file: log_file} do
    :telemetry.execute(
      [:backplane, :mcp_proxy, :tool_call, :stop],
      %{duration_ms: 12, system_time: System.system_time()},
      %{
        event_id: "evt-test-1",
        occurred_at: DateTime.utc_now(),
        domain: :mcp_proxy,
        operation: "tool_call",
        phase: :stop,
        severity: :info,
        context: %{request_id: "req-1", trace_id: "trace-1"},
        attributes: %{tool_name: "math::add", outcome: "success"},
        error: nil,
        payload_ref: nil
      }
    )

    :sys.get_state(RuntimeSink)
    Process.sleep(20)

    assert {:ok, decoded} = log_file |> File.read!() |> String.trim() |> Jason.decode()
    assert decoded["domain"] == "mcp_proxy"
    assert decoded["operation"] == "tool_call"
    assert decoded["event_id"] == "evt-test-1"
    assert decoded["attributes"]["tool_name"] == "math::add"
  end
end
