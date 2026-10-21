defmodule Backplane.McpProtocol.Test.HTTPServerTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Test.HTTPServer

  test "expect permits repeated requests and matches method and path" do
    server = HTTPServer.open()
    HTTPServer.expect(server, "POST", "/echo", &Plug.Conn.send_resp(&1, 200, "post"))
    HTTPServer.expect_once(server, "GET", "/echo", &Plug.Conn.send_resp(&1, 200, "get"))

    for _index <- 1..2 do
      assert request(server, :post, "/echo").body == "post"
    end

    assert request(server, :get, "/echo").body == "get"
    assert :ok = HTTPServer.verify!(server)
  end

  test "stubs allow no requests and wildcard routes allow arbitrary requests" do
    server = HTTPServer.open()
    HTTPServer.stub(server, "GET", "/unused", &Plug.Conn.send_resp(&1, 200, "unused"))
    HTTPServer.expect(server, &Plug.Conn.send_resp(&1, 200, "wildcard"))
    HTTPServer.expect_once(server, "GET", "/exact", &Plug.Conn.send_resp(&1, 200, "exact"))

    assert request(server, :get, "/exact").body == "exact"
    assert request(server, :delete, "/other").body == "wildcard"
    assert :ok = HTTPServer.verify!(server)
  end

  test "concurrent requests are counted without losing admissions" do
    server = HTTPServer.open()
    HTTPServer.expect(server, "GET", "/concurrent", &Plug.Conn.send_resp(&1, 200, "ok"))

    results =
      Task.async_stream(1..20, fn _index -> request(server, :get, "/concurrent").status end,
        max_concurrency: 10
      )
      |> Enum.to_list()

    assert results == List.duplicate({:ok, 200}, 20)
    assert :ok = HTTPServer.verify!(server)
  end

  test "an active SSE handler does not block other request admissions" do
    server = HTTPServer.open()
    test_pid = self()

    HTTPServer.expect_once(server, "GET", "/sse", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "data: ready\n\n")
      send(test_pid, {:stream_started, self()})

      receive do
        :release -> conn
      end
    end)

    HTTPServer.expect_once(server, "GET", "/ping", &Plug.Conn.send_resp(&1, 200, "pong"))
    socket = connect(server)
    assert :ok = :gen_tcp.send(socket, "GET /sse HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:stream_started, handler}
    assert request(server, :get, "/ping").body == "pong"
    assert :ok = HTTPServer.verify!(server)
    send(handler, :release)
  end

  test "down closes the listener and active connections without restarting" do
    server = HTTPServer.open()
    test_pid = self()

    HTTPServer.expect_once(server, "GET", "/sse", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "data: ready\n\n")
      send(test_pid, {:stream_started, self()})

      receive do
        :never -> conn
      end
    end)

    socket = connect(server)
    assert :ok = :gen_tcp.send(socket, "GET /sse HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:stream_started, handler}
    monitor = Process.monitor(handler)
    assert receive_until(socket, "data: ready\n\n\r\n") =~ "HTTP/1.1 200"
    assert :ok = HTTPServer.down(server)
    assert_receive {:DOWN, ^monitor, :process, ^handler, _reason}
    refute Process.alive?(server.listener)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary], 1000)

    assert :ok = HTTPServer.verify!(server)
  end

  test "on_exit reports missing, unexpected, duplicate and failed callback requests" do
    script = Path.expand("../../fixtures/http_server_failures.exs", __DIR__)
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2"] ++ paths ++ [script],
        stderr_to_stdout: true
      )

    assert status == 2, output
    assert output =~ "HTTP_SERVER_CONTRACT total=7 failures=7"
    assert output =~ "ExUnit.OnExitHandler"

    for message <- [
          "Missing HTTP request: GET /missing",
          "Unexpected HTTP request: GET /wrong-path",
          "Unexpected HTTP request: POST /expected",
          "Too many HTTP requests: GET /once",
          "handler exploded",
          "callback assertion propagated",
          "fixture_handler_throw"
        ] do
      assert output =~ message, output
    end
  end

  test "on_exit stops the complete fixture supervisor" do
    {:ok, holder} = Agent.start(fn -> nil end)

    on_exit(fn ->
      try do
        server = Agent.get(holder, & &1)
        refute Process.alive?(server.supervisor)
        refute Process.alive?(server.state)
        refute Process.alive?(server.listener)

        assert {:error, :econnrefused} =
                 :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary], 1000)
      after
        Agent.stop(holder)
      end
    end)

    server = HTTPServer.open()
    Agent.update(holder, fn _ -> server end)
  end

  defp request(server, method, path) do
    Req.request!(url: "http://127.0.0.1:#{server.port}#{path}", method: method, retry: false)
  end

  defp connect(server) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp receive_until(socket, marker, response \\ "") do
    if String.contains?(response, marker) do
      response
    else
      assert {:ok, chunk} = :gen_tcp.recv(socket, 0, 1000)
      receive_until(socket, marker, response <> chunk)
    end
  end
end
