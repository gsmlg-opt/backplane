defmodule Backplane.SkillProtocol.ReqLifecycleTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Client, Error, LifecycleHTTPServer}

  test "a stalled HTTP response is bounded by the overall deadline" do
    server = start_server(:stall)
    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Client.catalog(client(server.url, overall_timeout_ms: 500)) end)

    assert_receive {:http_request_started, server_pid}, 500
    assert server_pid == server.pid
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_500)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed >= 300
    assert elapsed < 1_200
    assert_request_closed(server)
  end

  test "slow response chunks do not reset the overall deadline" do
    server = start_server({:chunks, 100})
    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Client.catalog(client(server.url, overall_timeout_ms: 500)) end)

    assert_receive {:http_request_started, server_pid}, 500
    assert server_pid == server.pid
    assert_receive {:http_chunk_sent, 1}, 300
    assert_receive {:http_chunk_sent, 2}, 300
    assert {:error, %Error{code: :timeout}} = Task.await(task, 1_500)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed >= 300
    assert elapsed < 1_200
    assert_request_closed(server)
  end

  test "cancellation during an active HTTP response aborts its request" do
    server = start_server({:chunks, 20})
    cancelled = :atomics.new(1, [])

    task =
      Task.async(fn ->
        Client.catalog(
          client(server.url,
            cancelled?: fn -> :atomics.get(cancelled, 1) == 1 end,
            overall_timeout_ms: 5_000
          )
        )
      end)

    assert_receive {:http_request_started, server_pid}, 500
    assert server_pid == server.pid
    assert_receive {:http_chunk_sent, 1}, 200
    :atomics.put(cancelled, 1, 1)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :cancelled}} = Task.await(task, 500)
    assert System.monotonic_time(:millisecond) - started_at < 250
    assert_request_closed(server)
  end

  test "caller termination during an active HTTP response aborts its request" do
    server = start_server({:chunks, 20})

    caller =
      spawn(fn ->
        Client.catalog(client(server.url, overall_timeout_ms: 5_000))
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:http_request_started, server_pid}, 500
    assert server_pid == server.pid
    assert_receive {:http_chunk_sent, 1}, 200
    Process.exit(caller, :shutdown)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :shutdown}, 500
    assert_request_closed(server)
  end

  defp start_server(mode) do
    server = LifecycleHTTPServer.start(self(), mode)

    on_exit(fn ->
      if Process.alive?(server.pid) do
        Process.exit(server.pid, :kill)
        assert_receive {:DOWN, monitor, :process, pid, :killed}, 500
        assert monitor == server.monitor
        assert pid == server.pid
      end
    end)

    server
  end

  defp assert_request_closed(server) do
    server_monitor = server.monitor
    assert_receive {:http_request_closed, server_pid, reason}, 1_000
    assert server_pid == server.pid
    assert reason in [:closed, :econnreset]
    assert_receive {:DOWN, ^server_monitor, :process, server_pid, :normal}, 500
    assert server_pid == server.pid
  end

  defp client(endpoint, opts) do
    Client.new!(
      Keyword.merge(
        [
          endpoint: endpoint,
          source_id: "source-a",
          access_context_id: "tenant-a",
          max_attempts: 1
        ],
        opts
      )
    )
  end
end
