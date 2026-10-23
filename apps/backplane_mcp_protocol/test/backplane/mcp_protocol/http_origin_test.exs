defmodule Backplane.McpProtocol.HTTPOriginTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.Test.HTTPServer

  @moduletag capture_log: true

  setup do
    %{server: HTTPServer.open(), other: HTTPServer.open()}
  end

  test "relative redirects retain method, body, credentials and target query", %{server: server} do
    url = "http://localhost:#{server.port}"

    HTTPServer.expect_once(server, "POST", "/old/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "../new/mcp?tenant=two")
      |> Plug.Conn.resp(307, "")
    end)

    HTTPServer.expect_once(server, "POST", "/new/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["origin-secret"]
      assert conn.query_string == "tenant=two"
      assert {:ok, "payload", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, "accepted")
    end)

    request =
      HTTP.build(
        :post,
        url <> "/old/mcp?tenant=one",
        %{"authorization" => "origin-secret"},
        "payload"
      )

    assert {:ok, %{status: 200, body: "accepted"}} =
             HTTP.follow_redirect(request, allowed_origin: url)
  end

  test "cross-origin redirects stop before credentials reach the destination", %{
    server: server,
    other: other
  } do
    url = "http://localhost:#{server.port}"

    HTTPServer.expect_once(server, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://localhost:#{other.port}/mcp")
      |> Plug.Conn.resp(307, "")
    end)

    request = HTTP.build(:post, url <> "/mcp", %{"authorization" => "origin-secret"}, "payload")
    assert {:error, :cross_origin_redirect} = HTTP.follow_redirect(request, allowed_origin: url)
  end

  test "unconfined callers retain cross-origin redirect support", %{server: server, other: other} do
    HTTPServer.expect_once(server, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://localhost:#{other.port}/mcp")
      |> Plug.Conn.resp(307, "")
    end)

    HTTPServer.expect_once(other, fn conn -> Plug.Conn.resp(conn, 200, "legacy") end)
    request = HTTP.build(:get, "http://localhost:#{server.port}/mcp")
    assert {:ok, %{body: "legacy"}} = HTTP.follow_redirect(request)
  end

  test "the initial request is also confined", %{server: server, other: other} do
    request =
      HTTP.build(:get, "http://localhost:#{other.port}/mcp", %{"authorization" => "origin-secret"})

    assert {:error, :cross_origin_redirect} =
             HTTP.follow_redirect(request, allowed_origin: "http://localhost:#{server.port}")
  end

  test "missing or malformed Location returns a structured error", %{server: server} do
    for {location, index} <- Enum.with_index([nil, "http://[", "ftp://example.com/mcp"]) do
      HTTPServer.expect_once(server, "GET", "/malformed-#{index}", fn conn ->
        conn = if location, do: Plug.Conn.put_resp_header(conn, "location", location), else: conn
        Plug.Conn.resp(conn, 307, "")
      end)

      request = HTTP.build(:get, "http://localhost:#{server.port}/malformed-#{index}")
      assert {:error, :invalid_redirect} = HTTP.follow_redirect(request)
    end
  end

  test "redirect limit accepts the final response and stops further redirects", %{server: server} do
    HTTPServer.expect_once(server, "GET", "/final", &Plug.Conn.resp(&1, 200, "done"))

    assert {:ok, %{body: "done"}} =
             HTTP.follow_redirect(
               HTTP.build(:get, "http://localhost:#{server.port}/final"),
               [],
               0
             )

    HTTPServer.expect_once(server, "GET", "/loop", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/loop") |> Plug.Conn.resp(307, "")
    end)

    assert {:error, :max_redirects} =
             HTTP.follow_redirect(HTTP.build(:get, "http://localhost:#{server.port}/loop"), [], 0)
  end

  test "request origins preserve IPv6 hosts and default ports" do
    for url <- ["https://example.com/mcp", "http://[::1]/mcp", "https://[2001:db8::1]:8443/mcp"] do
      request = HTTP.build(:get, url)
      assert :ok = HTTP.check_origin(request, url)
    end

    request = HTTP.build(:get, "https://[::1]/mcp")
    assert :ok = HTTP.check_origin(request, "https://[::1]:443")
    assert {:error, :cross_origin_redirect} = HTTP.check_origin(request, "https://[::1]:444")
  end

  test "origin comparison normalizes default ports and rejects scheme, host, userinfo or port changes" do
    assert :ok = HTTP.check_origin("https://EXAMPLE.com/mcp", "https://example.com:443/base")

    for url <- [
          "http://example.com/mcp",
          "https://other.example/mcp",
          "https://example.com:444/mcp",
          "https://user:secret@example.com/mcp",
          "/relative"
        ] do
      assert {:error, :cross_origin_redirect} = HTTP.check_origin(url, "https://example.com")
    end
  end
end
