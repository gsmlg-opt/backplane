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
end
