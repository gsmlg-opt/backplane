defmodule Backplane.MetricsTest do
  use ExUnit.Case, async: true

  alias Backplane.Metrics

  test "inc increments a counter" do
    Metrics.inc("test_counter_1")
    Metrics.inc("test_counter_1")
    Metrics.inc("test_counter_1", 3)

    snapshot = Metrics.snapshot()
    assert snapshot.counters["test_counter_1"] == 5
  end

  test "record_timing tracks count and total" do
    Metrics.record_timing("test_timing_1", 1000)
    Metrics.record_timing("test_timing_1", 2000)

    snapshot = Metrics.snapshot()
    timing = snapshot.timings["test_timing_1"]
    assert timing.count == 2
    assert timing.total_us == 3000
    assert timing.avg_us == 1500
  end

  test "snapshot returns empty map when no metrics recorded" do
    # Just verify snapshot doesn't crash on a fresh table
    snapshot = Metrics.snapshot()
    assert is_map(snapshot)
  end

  test "telemetry handler increments mcp_requests_total" do
    before = Metrics.snapshot()
    before_count = get_in(before, [:counters, "mcp_requests_total"]) || 0

    :telemetry.execute(
      [:backplane, :mcp_request, :start],
      %{system_time: System.system_time()},
      %{method: "tools/list"}
    )

    after_snapshot = Metrics.snapshot()
    after_count = get_in(after_snapshot, [:counters, "mcp_requests_total"]) || 0
    assert after_count > before_count
  end

  test "oban job completion increments counters" do
    :telemetry.execute(
      [:oban, :job, :stop],
      %{duration: System.convert_time_unit(10_000, :microsecond, :native)},
      %{queue: :default, worker: "Backplane.Jobs.Reindexer"}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["oban_jobs_completed"] >= 1
    assert snapshot.counters["oban_jobs.default"] >= 1
    assert snapshot.counters["oban_workers.Backplane.Jobs.Reindexer"] >= 1
    assert snapshot.timings["oban_job_duration"].count >= 1
  end

  test "oban job exception increments failure counters" do
    :telemetry.execute(
      [:oban, :job, :exception],
      %{duration: System.convert_time_unit(1000, :microsecond, :native)},
      %{
        queue: :indexing,
        worker: "Backplane.Jobs.Reindexer",
        kind: :error,
        reason: %RuntimeError{}
      }
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["oban_jobs_failed"] >= 1
    assert snapshot.counters["oban_jobs_failed.indexing"] >= 1
  end

  test "telemetry handler records tool call timing" do
    :telemetry.execute(
      [:backplane, :tool_call, :stop],
      %{duration: System.convert_time_unit(5000, :microsecond, :native)},
      %{tool: "test::tool", result: :ok}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["tool_calls_success"] >= 1
    assert snapshot.timings["tool_call_duration"].count >= 1
  end

  test "tool_call error result increments error counter" do
    :telemetry.execute(
      [:backplane, :tool_call, :stop],
      %{duration: System.convert_time_unit(1000, :microsecond, :native)},
      %{tool: "test::error-tool", result: :error}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["tool_calls_errors"] >= 1
  end

  test "tool_call start increments total counter" do
    before = Metrics.snapshot()
    before_count = get_in(before, [:counters, "tool_calls_total"]) || 0

    :telemetry.execute(
      [:backplane, :tool_call, :start],
      %{system_time: System.system_time()},
      %{tool: "test::start-tool"}
    )

    after_snap = Metrics.snapshot()
    after_count = get_in(after_snap, [:counters, "tool_calls_total"]) || 0
    assert after_count > before_count
  end

  test "tool_call exception increments exception counter" do
    :telemetry.execute(
      [:backplane, :tool_call, :exception],
      %{duration: System.convert_time_unit(500, :microsecond, :native)},
      %{tool: "test::crash-tool", kind: :error, reason: %RuntimeError{}}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["tool_calls_exceptions"] >= 1
  end

  test "SSE stream start increments counter" do
    :telemetry.execute(
      [:backplane, :sse_stream, :start],
      %{system_time: System.system_time()},
      %{tool: "test::sse-tool"}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["sse_streams_started"] >= 1
  end

  test "SSE stream stop records timing" do
    :telemetry.execute(
      [:backplane, :sse_stream, :stop],
      %{duration: System.convert_time_unit(3000, :microsecond, :native)},
      %{tool: "test::sse-tool"}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.timings["sse_stream_duration"].count >= 1
  end

  test "mcp_request handler also increments per-method counter" do
    :telemetry.execute(
      [:backplane, :mcp_request, :start],
      %{system_time: System.system_time()},
      %{method: "initialize"}
    )

    snapshot = Metrics.snapshot()
    assert snapshot.counters["mcp_requests.initialize"] >= 1
  end

  test "snapshot includes upstreams list" do
    snapshot = Metrics.snapshot()
    assert is_list(snapshot.upstreams)
  end
end
