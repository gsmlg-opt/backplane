ExUnit.start(autorun: false, seed: 0)
{:ok, _applications} = Application.ensure_all_started(:gaoxy_http)

defmodule HTTPServerFailureContract do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Test.HTTPServer

  test "missing required request" do
    server = HTTPServer.open()
    HTTPServer.expect_once(server, "GET", "/missing", &Plug.Conn.send_resp(&1, 200, "ok"))
  end

  test "unexpected path" do
    server = HTTPServer.open()
    HTTPServer.stub(server, "GET", "/expected", &Plug.Conn.send_resp(&1, 200, "ok"))
    assert request(server, "GET", "/wrong-path") == 500
  end

  test "unexpected method" do
    server = HTTPServer.open()
    HTTPServer.stub(server, "GET", "/expected", &Plug.Conn.send_resp(&1, 200, "ok"))
    assert request(server, "POST", "/expected") == 500
  end

  test "concurrent duplicate requests" do
    server = HTTPServer.open()
    HTTPServer.expect_once(server, "GET", "/once", &Plug.Conn.send_resp(&1, 200, "ok"))

    results =
      Task.async_stream(1..2, fn _index -> request(server, "GET", "/once") end)
      |> Enum.map(fn {:ok, status} -> status end)
      |> Enum.sort()

    assert results == [200, 500]
  end

  test "callback raises" do
    server = HTTPServer.open()
    HTTPServer.expect_once(server, fn _conn -> raise "handler exploded" end)
    assert request(server, "GET", "/raise") == 500
  end

  test "callback assertion" do
    server = HTTPServer.open()
    HTTPServer.expect_once(server, fn _conn -> flunk("callback assertion propagated") end)
    assert request(server, "GET", "/assert") == 500
  end

  test "callback throws" do
    server = HTTPServer.open()
    HTTPServer.expect_once(server, fn _conn -> throw(:fixture_handler_throw) end)
    assert request(server, "GET", "/throw") == 500
  end

  defp request(server, method, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
    :gen_tcp.close(socket)
    ["HTTP/1.1", status | _rest] = String.split(response, " ")
    String.to_integer(status)
  end
end

result = ExUnit.run()
IO.puts("HTTP_SERVER_CONTRACT total=#{result.total} failures=#{result.failures}")
System.halt(if result.failures == 0, do: 0, else: 2)
