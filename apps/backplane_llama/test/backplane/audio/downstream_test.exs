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
    {:ok, socket} = h2_connect(port)
    h2_request(socket, 1, "POST", "/wait")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    h2_cancel(socket, 1)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2_000
    assert_health_h2(socket, 3)
  end

  test "HTTP/2 explicit abort preserves a sibling request", %{port: port} do
    {:ok, socket} = h2_connect(port)
    h2_request(socket, 1, "POST", "/wait")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    send(owner, :abort)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2_000
    assert_health_h2(socket, 3)
  end

  test "HTTP/2 flow-control blocked delivery expires without closing its connection", %{
    port: port
  } do
    {:ok, socket} = h2_connect(port)
    h2_put_settings(socket, initial_window_size: 1)
    h2_request(socket, 1, "POST", "/blocked")
    assert_receive {:started, owner, ""}, 2_000
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000
    h2_put_settings(socket, initial_window_size: 65_535)
    assert_health_h2(socket, 3)
  end

  defp h2_connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    preface = HTTP.HTTP2.connection_preface()
    {:ok, settings_payload} = HTTP.HTTP2.Settings.encode([])
    settings_frame = HTTP.HTTP2.Frame.encode(:settings, 0, 0, settings_payload)
    :ok = :gen_tcp.send(socket, [preface, settings_frame])
    {:ok, socket}
  end

  defp h2_request(socket, stream_id, method, path, body \\ "") do
    headers = [
      {":method", method},
      {":path", path},
      {":scheme", "http"},
      {":authority", "localhost"}
    ]

    block = HTTP.HTTP2.HPACK.encode_headers(headers)
    has_body? = byte_size(body) > 0
    flags = if has_body?, do: 0x4, else: 0x5
    frame = HTTP.HTTP2.Frame.encode(:headers, flags, stream_id, block)

    if has_body? do
      data_frame = HTTP.HTTP2.Frame.encode(:data, 0x1, stream_id, body)
      :ok = :gen_tcp.send(socket, [frame, data_frame])
    else
      :ok = :gen_tcp.send(socket, frame)
    end
  end

  defp h2_cancel(socket, stream_id) do
    frame = HTTP.HTTP2.Frame.encode(:rst_stream, 0, stream_id, <<8::32>>)
    :ok = :gen_tcp.send(socket, frame)
  end

  defp h2_put_settings(socket, settings_kw) do
    {:ok, payload} = HTTP.HTTP2.Settings.encode(settings_kw)
    frame = HTTP.HTTP2.Frame.encode(:settings, 0, 0, payload)
    :ok = :gen_tcp.send(socket, frame)
  end

  defp assert_health_h2(socket, stream_id) do
    h2_request(socket, stream_id, "GET", "/health")
    assert_data_received(socket, stream_id, "healthy")
    :gen_tcp.close(socket)
  end

  defp assert_data_received(socket, stream_id, expected, acc \\ "") do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    buffer = acc <> bytes

    case find_data_frame(buffer, stream_id) do
      {:ok, data} ->
        assert data =~ expected

      :more ->
        assert_data_received(socket, stream_id, expected, buffer)
    end
  end

  defp find_data_frame(
         <<length::24, 0x0::8, _flags::8, _r::1, stream_id::31, payload::binary-size(length),
           _rest::binary>>,
         stream_id
       ) do
    {:ok, payload}
  end

  defp find_data_frame(
         <<length::24, _type::8, _flags::8, _r::1, _sid::31, _payload::binary-size(length),
           rest::binary>>,
         stream_id
       ) do
    find_data_frame(rest, stream_id)
  end

  defp find_data_frame(_other, _stream_id), do: :more

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

end
