defmodule Backplane.McpProtocol.HTTPOriginTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.Test.HTTPServer
  alias Backplane.McpProtocol.Transport.SSE

  @moduletag capture_log: true

  test "plugin redirect policy refuses a different origin before headers are sent" do
    source = HTTPServer.open()
    destination = HTTPServer.open()
    source_url = "http://localhost:#{source.port}"
    destination_url = "http://localhost:#{destination.port}"

    HTTPServer.expect_once(source, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", destination_url <> "/stolen")
      |> Plug.Conn.send_resp(307, "")
    end)

    request =
      HTTP.build(:post, source_url <> "/mcp", %{"authorization" => "Bearer secret", "x-plugin" => "configured"}, "{}")

    assert {:error, :cross_origin_redirect} = HTTP.follow_redirect(request, allowed_origin: source_url)
    # The destination fixture records unexpected requests and fails on exit if any arrive.
  end

  test "same-origin relative redirects preserve headers, body and query" do
    server = HTTPServer.open()
    url = "http://localhost:#{server.port}"

    HTTPServer.expect_once(server, "POST", "/mcp", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/target?tenant=one") |> Plug.Conn.send_resp(307, "")
    end)

    HTTPServer.expect_once(server, "POST", "/target", fn conn ->
      assert conn.query_string == "tenant=one"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
      assert {:ok, "payload", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = HTTP.build(:post, url <> "/mcp", %{"authorization" => "Bearer secret"}, "payload")
    assert {:ok, %{status: 200, body: "ok"}} = HTTP.follow_redirect(request, allowed_origin: url)
  end

  test "unguarded existing callers may still follow redirects across origins" do
    source = HTTPServer.open()
    destination = HTTPServer.open()
    source_url = "http://localhost:#{source.port}"
    destination_url = "http://localhost:#{destination.port}"

    HTTPServer.expect_once(source, "GET", "/mcp", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", destination_url <> "/target") |> Plug.Conn.send_resp(307, "")
    end)

    HTTPServer.expect_once(destination, "GET", "/target", &Plug.Conn.send_resp(&1, 200, "ok"))
    assert {:ok, %{status: 200}} = HTTP.follow_redirect(HTTP.build(:get, source_url <> "/mcp"))
  end

  test "origin comparison covers scheme, host, effective port and userinfo" do
    assert :ok = HTTP.check_origin("https://EXAMPLE.com:443/path", "https://example.com/other")

    for destination <- [
          "http://example.com",
          "https://other.example",
          "https://example.com:444",
          "https://user@example.com"
        ] do
      assert {:error, :cross_origin_redirect} = HTTP.check_origin(destination, "https://example.com")
    end
  end

  test "SSE rejects cross-origin endpoint events before client initialization" do
    state = %{
      client: self(),
      server_url: "https://example.com",
      message_url: nil,
      http_options: [allowed_origin: "https://example.com/mcp"]
    }

    assert {:stop, :cross_origin_endpoint, ^state} = SSE.handle_info({:endpoint, "https://other.example/messages"}, state)
    assert {:stop, :cross_origin_endpoint, ^state} = SSE.handle_info({:endpoint, "//other.example/messages"}, state)
    refute_received {:"$gen_cast", :initialize}
    assert {:noreply, %{message_url: "https://example.com/messages"}} = SSE.handle_info({:endpoint, "/messages"}, state)
    assert_receive {:"$gen_cast", :initialize}
  end
end
