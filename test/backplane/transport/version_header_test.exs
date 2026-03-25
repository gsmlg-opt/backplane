defmodule Backplane.Transport.VersionHeaderTest do
  use Backplane.ConnCase, async: true

  test "responses include X-Backplane-Version header" do
    conn =
      Plug.Test.conn(:get, "/health")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    versions =
      conn.resp_headers
      |> Enum.filter(fn {k, _} -> k == "x-backplane-version" end)
      |> Enum.map(fn {_, v} -> v end)

    assert [version] = versions
    assert version =~ ~r/^\d+\.\d+\.\d+$/
  end

  test "responses include X-MCP-Protocol-Version header" do
    conn =
      Plug.Test.conn(:get, "/health")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

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
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
    assert "x-mcp-protocol-version" in header_names
  end

  test "version headers present on 404 responses" do
    conn =
      Plug.Test.conn(:get, "/nonexistent")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 404
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
  end
end
