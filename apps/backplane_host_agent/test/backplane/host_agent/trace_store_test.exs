defmodule Backplane.HostAgent.TraceStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Trace, TraceStore}

  @moduletag :tmp_dir

  test "writes enriched JSONL lines with sanitized telemetry data", %{tmp_dir: tmp_dir} do
    handler_id = "trace-store-test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {TraceStore, dir: tmp_dir, name: nil, retention_days: 14, handler_id: handler_id}
      )

    ctx = Trace.new_ctx()

    Trace.with_ctx(ctx, fn ->
      :telemetry.execute(
        [:backplane, :host_agent, :memory, :call, :stop],
        %{duration: 12},
        %{method: :list, nested: %{pid: self()}}
      )
    end)

    assert eventually(fn -> trace_lines(tmp_dir) != [] end)
    [item] = trace_lines(tmp_dir)

    assert item["seq"] == 1
    assert item["trace_id"] == ctx.trace_id
    assert item["span_id"] == ctx.span_id
    assert item["parent_id"] == nil
    assert item["event"] == "backplane.host_agent.memory.call.stop"
    assert item["measurements"] == %{"duration" => 12}
    assert item["metadata"]["method"] == "list"
    assert item["metadata"]["nested"]["pid"] =~ "#PID<"

    GenServer.stop(pid)
  end

  test "continues sequence from counter file", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "counter.txt"), "41")

    {:ok, pid} =
      start_supervised(
        {TraceStore,
         dir: tmp_dir,
         name: nil,
         retention_days: 14,
         handler_id: "trace-store-counter-#{System.unique_integer([:positive])}"}
      )

    TraceStore.record(pid, [:backplane, :host_agent, :memory_pruner, :run], %{}, %{})
    assert eventually(fn -> match?([%{"seq" => 42}], trace_lines(tmp_dir)) end)
  end

  test "prunes trace files older than retention on startup", %{tmp_dir: tmp_dir} do
    old_date = Date.utc_today() |> Date.add(-20) |> Date.to_iso8601()
    old_path = Path.join(tmp_dir, "traces-#{old_date}.jsonl")
    File.write!(old_path, Jason.encode!(%{"seq" => 1}) <> "\n")

    {:ok, _pid} =
      start_supervised(
        {TraceStore,
         dir: tmp_dir,
         name: nil,
         retention_days: 14,
         handler_id: "trace-store-prune-#{System.unique_integer([:positive])}"}
      )

    refute File.exists?(old_path)
  end

  defp trace_lines(dir) do
    dir
    |> Path.join("traces-*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.stream!(:line, [])
      |> Enum.map(&Jason.decode!/1)
    end)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
