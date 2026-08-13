defmodule Backplane.HostAgent.Memory.CapturePerformanceTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.MemoryRouter

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir
  @warmup_count 20
  @sample_count 200

  defmodule UnexpectedRemoteProxy do
    def call(_method, _arguments, _opts), do: raise("asynchronous capture waited remotely")
  end

  setup %{tmp_dir: tmp_dir} do
    previous_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)

    spool =
      start_supervised!(
        {Spool,
         database: Path.join(tmp_dir, "capture.db"),
         name: nil,
         id: {:capture_performance_spool, System.unique_integer([:positive])}}
      )

    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: "trusted-host",
      spool: spool,
      spool_module: Spool,
      memory_proxy_module: UnexpectedRemoteProxy,
      config: %{inject_context: true, context_timeout_ms: 1_500}
    })

    on_exit(fn -> restore_env(:capture_runtime, previous_runtime) end)

    {:ok, spool: spool}
  end

  @tag :performance
  test "privacy-filtered durable local enqueue p95 stays below 50 ms without a remote wait", %{
    spool: spool
  } do
    Enum.each(1..@warmup_count, &enqueue!({:warmup, &1}))

    latencies_ms = Enum.map(1..@sample_count, &enqueue!({:sample, &1}))
    p50_ms = percentile(latencies_ms, 50)
    p95_ms = percentile(latencies_ms, 95)
    max_ms = Enum.max(latencies_ms)

    IO.puts(
      "M13 local enqueue latency samples=#{@sample_count} warmups=#{@warmup_count} " <>
        "p50=#{format_ms(p50_ms)}ms p95=#{format_ms(p95_ms)}ms max=#{format_ms(max_ms)}ms"
    )

    assert %{pending_depth: pending_depth} = Spool.stats(spool)
    assert pending_depth == @warmup_count + @sample_count

    events = Spool.next_batch(spool, pending_depth, 10_000_000)
    assert length(events) == pending_depth

    encoded = Jason.encode!(events)
    refute encoded =~ "sk-performance-secret"
    refute encoded =~ "must-not-reach-disk"
    assert encoded =~ "[REDACTED]"
    assert encoded =~ "[PRIVATE]"

    assert p95_ms < 50.0,
           "local durable enqueue p95 was #{format_ms(p95_ms)} ms; expected below 50 ms"
  end

  defp enqueue!(identity) do
    source_id = identity |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    body = %{
      "hook_event_name" => "UserPromptSubmit",
      "session_id" => "latency-session",
      "source_event_id" => source_id,
      "cwd" => "/workspace/backplane",
      "occurred_at" => "2026-08-12T00:00:00Z",
      "prompt" => "use sk-performance-secret and hide <private>must-not-reach-disk</private>"
    }

    started_at = System.monotonic_time()

    response =
      :post
      |> conn(
        "/capture/v1/hooks/claude_code/user-prompt-submit",
        Jason.encode!(body)
      )
      |> put_req_header("content-type", "application/json")
      |> then(&MemoryRouter.call(&1, MemoryRouter.init([])))

    elapsed_ms =
      started_at
      |> then(&(System.monotonic_time() - &1))
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1_000)

    assert response.status == 202
    assert %{"ok" => true, "status" => "accepted"} = Jason.decode!(response.resp_body)

    elapsed_ms
  end

  defp percentile(values, percentile) do
    index = ceil(length(values) * percentile / 100) - 1
    values |> Enum.sort() |> Enum.fetch!(index)
  end

  defp format_ms(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
