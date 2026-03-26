defmodule Backplane.Transport.VersionHeaderTest do
  use Backplane.ConnCase, async: true

  alias Backplane.Transport.Router

  test "responses include X-Backplane-Version header" do
    conn =
      conn(:get, "/health")
      |> Router.call(Router.init([]))

    versions =
      conn.resp_headers
      |> Enum.filter(fn {k, _} -> k == "x-backplane-version" end)
      |> Enum.map(fn {_, v} -> v end)

    assert [version] = versions
    assert version =~ ~r/^\d+\.\d+\.\d+$/
  end

  test "responses include X-MCP-Protocol-Version header" do
    conn =
      conn(:get, "/health")
      |> Router.call(Router.init([]))

    protocols =
      conn.resp_headers
      |> Enum.filter(fn {k, _} -> k == "x-mcp-protocol-version" end)
      |> Enum.map(fn {_, v} -> v end)

    assert [protocol] = protocols
    assert protocol =~ ~r/^\d{4}-\d{2}-\d{2}$/
  end

  test "version headers present on MCP endpoint" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
    assert "x-mcp-protocol-version" in header_names
  end

  test "version headers present on 404 responses" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(Router.init([]))

    assert conn.status == 404
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
  end

  describe "plug unit tests" do
    test "init/1 passes options through" do
      assert Backplane.Transport.VersionHeader.init(foo: :bar) == [foo: :bar]
    end

    test "call/2 sets both headers on a bare conn" do
      conn =
        conn(:get, "/")
        |> Backplane.Transport.VersionHeader.call([])

      assert get_resp_header(conn, "x-backplane-version") |> length() == 1
      assert get_resp_header(conn, "x-mcp-protocol-version") |> length() == 1
    end
  end
end
