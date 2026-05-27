defmodule BackplaneTelemetryTest do
  use ExUnit.Case, async: false

  alias BackplaneTelemetry.TelemetryLogger

  setup do
    # Generate a temporary file path
    temp_dir = System.tmp_dir!()
    log_file = Path.join(temp_dir, "telemetry_test_#{System.unique_integer([:positive])}.jsonl")

    # Override application configuration
    Application.put_env(:backplane_telemetry, TelemetryLogger, [
      log_to_logger: false,
      log_to_console: false,
      log_to_file: log_file
    ])

    # Restart TelemetryLogger to pick up the test config
    if Process.whereis(TelemetryLogger) do
      GenServer.stop(TelemetryLogger)
    end

    {:ok, pid} = TelemetryLogger.start_link()

    on_exit(fn ->
      # Clean up files and stop process if still alive
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end

      File.rm(log_file)
    end)

    %{log_file: log_file}
  end

  test "captures and logs host agent connection events to JSONL file", %{log_file: log_file} do
    ref = make_ref()
    host_id = "test-host-#{inspect(ref)}"

    :telemetry.execute(
      [:backplane, :host_agent, :connect],
      %{system_time: System.system_time()},
      %{host_id: host_id, host_name: "test-agent-1", auth_token_id: "token-123"}
    )

    # Allow GenServer to process the cast asynchronously
    Process.sleep(50)

    assert File.exists?(log_file)
    content = File.read!(log_file)
    assert content != ""

    # Parse JSON line
    assert {:ok, decoded} = Jason.decode(content)
    assert decoded["event"] == "backplane.host_agent.connect"
    assert decoded["metadata"]["host_id"] == host_id
    assert decoded["metadata"]["host_name"] == "test-agent-1"
    assert decoded["metadata"]["auth_token_id"] == "token-123"
  end

  test "captures and logs memory database access events", %{log_file: log_file} do
    :telemetry.execute(
      [:backplane, :memory, :access, :stop],
      %{duration: 10_000_000},
      %{action: "remember", status: :ok, memory_id: "mem-123"}
    )

    Process.sleep(50)

    assert File.exists?(log_file)
    content = File.read!(log_file)
    assert {:ok, decoded} = Jason.decode(content)
    assert decoded["event"] == "backplane.memory.access.stop"
    assert decoded["metadata"]["action"] == "remember"
    assert decoded["metadata"]["status"] == "ok"
    assert decoded["metadata"]["memory_id"] == "mem-123"
  end

  test "sanitizes non-serializable terms like PIDs and structs safely", %{log_file: log_file} do
    # Emit an event with PID and a custom struct
    pid = self()
    struct_val = %URI{host: "localhost", path: "/test"}

    :telemetry.execute(
      [:backplane, :skills, :access, :stop],
      %{duration: 5_000_000},
      %{action: "ingest", pid: pid, uri: struct_val}
    )

    Process.sleep(50)

    content = File.read!(log_file)
    assert {:ok, decoded} = Jason.decode(content)
    assert decoded["metadata"]["pid"] == inspect(pid)
    assert decoded["metadata"]["uri"]["host"] == "localhost"
    assert decoded["metadata"]["uri"]["path"] == "/test"
  end
end
