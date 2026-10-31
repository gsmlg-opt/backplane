defmodule Backplane.Audio.DownstreamTest do
  use ExUnit.Case, async: false

  alias Backplane.Audio.Downstream

  defmodule Endpoint do
    import Plug.Conn

    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = body(conn)

      case conn.request_path do
        "/health" ->
          send_resp(conn, 200, "healthy")

        "/blocked" ->
          deadline = System.monotonic_time(:millisecond) + 400
          {:ok, downstream} = Downstream.start(conn, deadline)
          send(owner, {:started, self(), body})

          Downstream.deliver(downstream, deadline, fn ->
            conn = send_chunked(conn, 200)
            bytes = :binary.copy("a", 65_536)

            Enum.reduce(1..2048, conn, fn _, current ->
              {:ok, next} = chunk(current, bytes)
              next
            end)
          end)

        _ ->
          # WORKAROUND(upstream): gsmlg-dev/gaoxy#19 - 64KB pipelined polls read 1 byte per iteration, needing extra deadline
          deadline = System.monotonic_time(:millisecond) + 30_000
          {:ok, downstream} = Downstream.start(conn, deadline)
          send(owner, {:started, self(), body})
          wait(conn, downstream, owner)
      end
    end

    defp body(conn, acc \\ []) do
      case read_body(conn, length: 1_024, read_length: 1_024) do
        {:more, bytes, next} -> body(next, [bytes | acc])
        {:ok, bytes, next} -> {:ok, IO.iodata_to_binary(Enum.reverse([bytes | acc])), next}
      end
    end

    defp wait(conn, downstream, owner) do
      case Downstream.poll(conn, downstream) do
        {:ok, next} ->
          receive do
            :finish ->
              sent =
                Downstream.deliver(downstream, downstream.deadline, fn ->
                  send_resp(next, 200, "first")
                end)

              {:ok, restored} = Downstream.restore(sent, downstream)
              restored

            :abort ->
              {:ok, aborted} = Downstream.abort(next)
              aborted
          after
            10 -> wait(next, downstream, owner)
          end

        {:error, error, next} ->
          send(owner, {:downstream_error, self(), error.code})
          {:ok, aborted} = Downstream.abort(next)
          aborted
      end
    end
  end

  setup do
    server =
      start_supervised!(
        {Gaoxy.HTTP,
         plug: {Endpoint, self()},
         port: 0,
         http_limits: %{max_buffer_bytes: 65_536},
         limits: %{max_bytes: 268_435_456},
         protocols: [:http2, :http1],
         h2c: :prior_knowledge}
      )

    {:ok, {_, port}} = Gaoxy.info(server, :http).local
    %{port: port}
  end

  test "generic Plug connections retain their existing delivery behavior" do
    conn = Plug.Test.conn(:get, "/")
    assert {:ok, nil} = Downstream.start(conn, System.monotonic_time(:millisecond) + 1_000)
    assert {:ok, ^conn} = Downstream.poll(conn, nil)
    assert ^conn = Downstream.deliver(nil, 0, fn -> conn end)
    assert {:ok, ^conn} = Downstream.restore(conn, nil)
  end

  test "real TCP closure is observed while the request waits", %{port: port} do
    socket = tcp(port)
    :ok = :gen_tcp.send(socket, request("/wait", "body"))
    assert_receive {:started, owner, "body"}, 2_000
    monitor = Process.monitor(owner)
    :ok = :gen_tcp.close(socket)
    assert_receive {:downstream_error, ^owner, "audio_cancelled"}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2_000
  end

  # WORKAROUND(upstream): gsmlg-dev/gaoxy#19 - 64KB pipelined polls read 1 byte per iteration, needing extra timeout
  test "peer closure is observed with exactly 65536 pipelined bytes", %{port: port} do
    socket = tcp(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, request("/wait", ""))
    assert_receive {:started, owner, ""}, 10_000
    monitor = Process.monitor(owner)
    pipeline = request("/health", :binary.copy("x", 65_471))
    assert byte_size(pipeline) == 65_536
    :ok = :gen_tcp.send(socket, pipeline)
    :ok = :gen_tcp.shutdown(socket, :write)
    assert_receive {:downstream_error, ^owner, "audio_cancelled"}, 30_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 30_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 30_000)
  end

  test "polling retains body-read state and pipelined keepalive requests", %{port: port} do
    socket = tcp(port)
    upload = :binary.copy("upload", 12_000)
    :ok = :gen_tcp.send(socket, request("/wait", upload))
    assert_receive {:started, owner, ^upload}, 10_000
    :ok = :gen_tcp.send(socket, request("/health", ""))
    send(owner, :finish)
    bytes = responses(socket, "")
    assert length(:binary.matches(bytes, "HTTP/1.1 200")) == 2
    assert bytes =~ "first"
    assert bytes =~ "healthy"
    :gen_tcp.close(socket)
  end

  test "excess pipelined input is bounded at 65536 bytes", %{port: port} do
    socket = tcp(port)
    :ok = :gen_tcp.send(socket, request("/wait", ""))
    assert_receive {:started, owner, ""}, 10_000
    :ok = :gen_tcp.send(socket, :binary.copy("x", 65_537))
    assert_receive {:downstream_error, ^owner, "audio_pipeline_too_large"}, 30_000
    :gen_tcp.close(socket)
  end

  test "exactly 65536 pipelined bytes retain the next keepalive request", %{port: port} do
    socket = tcp(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, request("/wait", ""))
    assert_receive {:started, owner, ""}, 10_000

    body = :binary.copy("x", 65_471)
    pipeline = request("/health", body)
    assert byte_size(pipeline) == 65_536
    :ok = :gen_tcp.send(socket, pipeline)
    send(owner, :finish)

    bytes = responses(socket, "", 30_000)
    assert length(:binary.matches(bytes, "HTTP/1.1 200")) == 2
    assert bytes =~ "first"
    assert bytes =~ "healthy"
  end

  test "a real blocked TCP delivery obeys the application deadline", %{port: port} do
    socket = tcp(port)
    :ok = :gen_tcp.send(socket, request("/blocked", ""))
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000
    :gen_tcp.close(socket)
  end

  test "initial body read retains exactly 65536 pipelined bytes and keepalive", %{port: port} do
    socket = tcp(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    pipeline = request("/health", :binary.copy("x", 65_471))
    assert byte_size(pipeline) == 65_536
    :ok = :gen_tcp.send(socket, request("/wait", "upload") <> pipeline)
    assert_receive {:started, owner, "upload"}, 2_000
    send(owner, :finish)
    bytes = responses(socket, "")
    assert length(:binary.matches(bytes, "HTTP/1.1 200")) == 2
    assert bytes =~ "first"
    assert bytes =~ "healthy"
  end

  test "initial body read rejects 65537 pipelined bytes", %{port: port} do
    socket = tcp(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    pipeline = request("/health", :binary.copy("x", 65_472))
    assert byte_size(pipeline) == 65_537
    :ok = :gen_tcp.send(socket, request("/wait", "upload") <> pipeline)
    assert_receive {:started, owner, "upload"}, 2_000
    assert_receive {:downstream_error, ^owner, "audio_pipeline_too_large"}, 30_000
  end

  test "HTTP/2 peer reset releases only its request owner", %{port: port} do
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, request_ref} = Mint.HTTP.request(conn, "POST", "/wait", [], "")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    {:ok, conn} = Mint.HTTP2.cancel_request(conn, request_ref)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2_000
    assert_health(conn)
  end

  test "HTTP/2 explicit abort preserves a sibling request", %{port: port} do
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, _request_ref} = Mint.HTTP.request(conn, "POST", "/wait", [], "")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    send(owner, :abort)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2_000
    assert_health(conn)
  end

  test "HTTP/2 flow-control blocked delivery expires without closing its connection", %{
    port: port
  } do
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn} = Mint.HTTP2.put_settings(conn, initial_window_size: 1)
    {:ok, conn, _request_ref} = Mint.HTTP.request(conn, "POST", "/blocked", [], "")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000
    {:ok, conn} = Mint.HTTP2.put_settings(conn, initial_window_size: 65_535)
    assert_health(conn)
  end

  defp tcp(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, recbuf: 1_024], 2_000)

    socket
  end

  defp request(path, body),
    do:
      "POST #{path} HTTP/1.1\r\nhost: localhost\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
        body

  defp responses(socket, acc, timeout \\ 30_000) do
    if String.contains?(acc, "healthy") do
      acc
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, timeout)
      responses(socket, acc <> bytes, timeout)
    end
  end

  defp assert_health(conn) do
    {:ok, conn, request_ref} = Mint.HTTP.request(conn, "GET", "/health", [], nil)
    {conn, events} = until_done(conn, request_ref, [])
    assert {:status, request_ref, 200} in events
    assert {:data, request_ref, "healthy"} in events
    Mint.HTTP.close(conn)
  end

  defp until_done(conn, request_ref, acc) do
    {:ok, conn, events} = Mint.HTTP.recv(conn, 0, 2_000)
    acc = acc ++ events

    if {:done, request_ref} in acc,
      do: {conn, acc},
      else: until_done(conn, request_ref, acc)
  end
end
