defmodule Backplane.SkillProtocol.FetchLifecycleTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Client, Error, LifecycleHTTPServer}
  alias Backplane.SkillProtocol.Transport.Fetch

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

  test "a streamed body beyond the byte cap aborts its request" do
    server = start_server({:chunks, 5})

    assert {:error, %Error{code: :limit_exceeded}} =
             Client.catalog(client(server.url, max_json_bytes: 3, overall_timeout_ms: 5_000))

    assert_receive {:http_chunk_sent, 3}, 500
    assert_request_closed(server)
  end

  test "the transport returns status, first header values and the raw body without redirects" do
    server =
      start_server(
        {:response, 302,
         [
           {"Location", "/elsewhere"},
           {"Content-Type", "application/json"},
           {"X-Dup", "first"},
           {"X-Dup", "second"}
         ], ~s({"not":"decoded"})}
      )

    assert {:ok, %{status: 302, headers: headers, body: ~s({"not":"decoded"})}} =
             Fetch.request(transport_request(server.url <> "/skill-protocol/v1/catalog"))

    assert headers["location"] == "/elsewhere"
    assert headers["content-type"] == "application/json"
    assert headers["x-dup"] == "first"
    assert_receive {:http_request_started, _server_pid}, 500
  end

  test "the transport enforces the byte cap on buffered bodies" do
    server = start_server({:response, 200, [{"content-type", "application/json"}], "12345"})

    assert {:error, :response_too_large} =
             Fetch.request(%{transport_request(server.url) | max_bytes: 4})
  end

  test "the transport reports a stalled response as a deadline timeout" do
    server = start_server(:stall)

    assert {:error, :timeout} =
             Fetch.request(%{
               transport_request(server.url)
               | timeout_ms: 5_000,
                 deadline: deadline(200)
             })

    assert_request_closed(server)
  end

  test "the transport reports cancellation of an active response" do
    server = start_server({:chunks, 20})
    cancelled = :atomics.new(1, [])
    cancelled? = fn -> :atomics.get(cancelled, 1) == 1 end

    task =
      Task.async(fn ->
        Fetch.request(%{transport_request(server.url) | cancelled?: cancelled?})
      end)

    assert_receive {:http_chunk_sent, 1}, 500
    :atomics.put(cancelled, 1, 1)

    assert {:error, :cancelled} = Task.await(task, 500)
    assert_request_closed(server)
  end

  defp transport_request(url) do
    %{
      url: url,
      headers: %{"accept" => "application/json"},
      timeout_ms: 5_000,
      deadline: deadline(5_000),
      max_bytes: 1_024,
      cancelled?: fn -> false end
    }
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

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
