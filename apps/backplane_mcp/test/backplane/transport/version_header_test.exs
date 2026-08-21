defmodule Backplane.Transport.VersionHeaderTest do
  use Backplane.ConnCase, async: true

  alias Backplane.Transport.{McpPlug, VersionHeader}

  @modern_version "2026-07-28"

  test "responses include X-Backplane-Version header" do
    conn =
      conn(:get, "/health")
      |> McpPlug.call(McpPlug.init([]))

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
      |> McpPlug.call(McpPlug.init([]))

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
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
    assert "x-mcp-protocol-version" in header_names
  end

  test "version headers present on 404 responses" do
    conn =
      conn(:get, "/nonexistent")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 404
    header_names = Enum.map(conn.resp_headers, fn {k, _} -> k end)
    assert "x-backplane-version" in header_names
  end

  describe "plug unit tests" do
    test "init/1 passes options through" do
      assert VersionHeader.init(foo: :bar) == [foo: :bar]
    end

    test "call/2 sets both headers before a bare conn is sent" do
      conn =
        conn(:get, "/")
        |> VersionHeader.call([])
        |> send_resp(204, "")

      assert get_resp_header(conn, "x-backplane-version") |> length() == 1
      assert get_resp_header(conn, "x-mcp-protocol-version") |> length() == 1
    end
  end

  test "modern responses report the selected modern protocol version" do
    conn = modern_conn("server/discover", %{}) |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "x-mcp-protocol-version") == [@modern_version]
  end

  test "idempotent modern retries retain the selected modern protocol version" do
    key = "modern-version-#{System.unique_integer([:positive])}"

    first =
      modern_conn("server/discover", %{})
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    retry =
      modern_conn("server/discover", %{})
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    assert first.status == 200
    assert retry.status == 200
    assert get_resp_header(first, "x-mcp-protocol-version") == [@modern_version]
    assert get_resp_header(retry, "x-mcp-protocol-version") == [@modern_version]
  end

  test "legacy initialize reports its negotiated protocol version" do
    conn = legacy_initialize("2025-03-26")

    assert conn.status == 200
    assert get_resp_header(conn, "x-mcp-protocol-version") == ["2025-03-26"]
    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    on_exit(fn -> Backplane.Transport.Session.delete(session_id) end)
  end

  test "subsequent legacy requests report the stored session version" do
    initialized = legacy_initialize("2025-06-18")
    assert [session_id] = get_resp_header(initialized, "mcp-session-id")
    on_exit(fn -> Backplane.Transport.Session.delete(session_id) end)

    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "x-mcp-protocol-version") == ["2025-06-18"]
  end

  test "malformed JSON retains a negotiated legacy session version without mutating sessions" do
    initialized = legacy_initialize("2025-03-26")
    assert [session_id] = get_resp_header(initialized, "mcp-session-id")
    on_exit(fn -> Backplane.Transport.Session.delete(session_id) end)
    before_count = Backplane.Transport.Session.count()

    conn =
      conn(:post, "/", "not json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body) == %{"error" => "Malformed request body"}
    assert get_resp_header(conn, "x-mcp-protocol-version") == ["2025-03-26"]
    assert Backplane.Transport.Session.count() == before_count
    assert Backplane.Transport.Session.get(session_id)
  end

  test "unknown and duplicate legacy session headers fall back to the legacy default" do
    header_sets = [
      [{"mcp-session-id", "missing-session"}],
      [{"mcp-session-id", "one"}, {"Mcp-Session-Id", "two"}],
      [{"mcp-session-id", ""}]
    ]

    for raw_headers <- header_sets do
      conn =
        conn(:post, "/", "not json")
        |> put_req_header("content-type", "application/json")

      conn = %{conn | req_headers: raw_headers ++ conn.req_headers}
      conn = McpPlug.call(conn, McpPlug.init([]))

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body) == %{"error" => "Malformed request body"}
      assert get_resp_header(conn, "x-mcp-protocol-version") == ["2025-11-25"]
    end
  end

  test "unmarked legacy responses retain the 2025-11-25 default" do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert get_resp_header(conn, "x-mcp-protocol-version") == ["2025-11-25"]
  end

  defp legacy_initialize(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "clientInfo" => %{"name" => "version-header-test", "version" => "1.0.0"},
        "capabilities" => %{}
      }
    }

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> McpPlug.call(McpPlug.init([]))
  end

  defp modern_conn(method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => @modern_version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", @modern_version)
    |> put_req_header("mcp-method", method)
  end
end
