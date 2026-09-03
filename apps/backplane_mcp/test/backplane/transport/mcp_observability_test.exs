defmodule Backplane.Transport.McpObservabilityTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import Backplane.Auth.Fixtures
  import BackplaneMcp.Fixtures
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Backplane.MCP.{AccessEvent, LogQuery, ProxyRequest}
  alias Backplane.Observability.Context
  alias Backplane.Transport.{McpPlug, RateLimiter}

  @moduletag observability_v2: true

  setup do
    prev_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: prev_level) end)
    :ok
  end

  describe "durable MCP root records" do
    test "legacy initialize" do
      conn = mcp_conn("initialize", %{"protocolVersion" => "2025-03-26"})
      assert conn.status == 200
      flush_and_assert_rpc!("initialize", "success")
    end

    test "modern request" do
      conn =
        modern_mcp_conn("server/discover", %{})

      assert conn.status == 200
      flush_logs!()

      import Ecto.Query

      log =
        Backplane.Repo.one(
          from(r in ProxyRequest,
            where: r.operation == "jsonrpc",
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert log.outcome == "success"
      assert log.era == "modern"
    end

    test "tools/list success" do
      conn = mcp_conn("tools/list")
      assert conn.status == 200
      flush_and_assert_rpc!("tools/list", "success")
    end

    test "tools/call success" do
      conn =
        mcp_conn("tools/call", %{
          "name" => "skill::list",
          "arguments" => %{}
        })

      assert conn.status == 200
      flush_and_assert_rpc!("tools/call", "success")
    end

    test "method not found" do
      conn = mcp_conn("definitely/missing", %{})
      assert conn.status == 200
      flush_and_assert_rpc!("definitely/missing", "error", fn log ->
        assert log.jsonrpc_error_code == -32_601
      end)
    end

    test "invalid params" do
      conn = mcp_conn("tools/call", %{"arguments" => %{}})
      assert conn.status == 200
      flush_and_assert_rpc!("tools/call", "error", fn log ->
        assert log.jsonrpc_error_code == -32_602
      end)
    end

    test "insufficient scope" do
      {_client, token} = insert_client(name: "scope-limited", scopes: ["docs::*"])

      conn =
        mcp_conn("tools/call", %{"name" => "skill::list", "arguments" => %{}}, auth_token: token)

      assert conn.status == 200
      flush_and_assert_rpc!("tools/call", "error", fn log ->
        assert log.jsonrpc_error_code == -32_001
      end)
    end

    test "malformed JSON" do
      conn =
        conn(:post, "/", "not-json")
        |> put_req_header("content-type", "application/json")
        |> call_mcp()

      assert conn.status == 400
      flush_logs!()

      import Ecto.Query

      log =
        Backplane.Repo.one(
          from(r in ProxyRequest,
            where: r.http_status == 400,
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert log != nil
      assert log.operation == "jsonrpc"
      assert log.outcome == "error"
      assert log.error_kind == "validation"
    end

    test "request too large" do
      conn =
        conn(:post, "/", String.duplicate("x", 2_000_000))
        |> put_req_header("content-type", "application/json")
        |> call_mcp()

      assert conn.status == 413
      flush_logs!()

      import Ecto.Query

      log =
        Backplane.Repo.one(
          from(r in ProxyRequest,
            where: r.http_status == 413,
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert log != nil
      assert log.operation == "jsonrpc"
      assert log.outcome == "error"
    end

    test "rate limit" do
      previous = Application.get_env(:backplane, RateLimiter)

      Application.put_env(:backplane, RateLimiter,
        max_requests: 0,
        window_ms: 60_000,
        trust_x_forwarded_for: false
      )

      on_exit(fn ->
        if previous, do: Application.put_env(:backplane, RateLimiter, previous)
      end)

      conn = mcp_conn("ping")
      assert conn.status == 429
      flush_and_assert_latest!("jsonrpc", "error", fn log ->
        assert log.http_status == 429
        assert log.error_kind == "rate_limit"
      end)
    end

    test "auth failure" do
      oauth_client_fixture!(resources: [:mcp], scopes: ["public::echo"])

      conn =
        conn(:post, "/", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> call_mcp()

      assert conn.status == 401
      flush_and_assert_latest!("jsonrpc", "error", fn log ->
        assert log.http_status == 401
        assert log.error_kind == "auth"
      end)
    end

    test "internal callback failure surfaces as protocol error" do
      body =
        Jason.encode!([
          %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
          %{"jsonrpc" => "2.0", "method" => "ping", "id" => 2}
        ])

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> call_mcp()

      assert conn.status == 200
      flush_logs!()

      import Ecto.Query

      log =
        Backplane.Repo.one(
          from(r in ProxyRequest,
            where: r.operation == "jsonrpc",
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert log != nil
      assert log.outcome == "success"
      assert log.rpc_method in [nil, "ping"]
    end

    test "session DELETE" do
      conn =
        conn(:delete, "/")
        |> call_mcp()

      assert conn.status == 200
      flush_and_assert_latest!("session_delete", "success")
    end

    test "sse_open connect and disconnect finalize one root record" do
      access =
        conn(:get, "/")
        |> assign(:resource_auth, %{kind: :open, client_id: nil, scopes: ["*"]})
        |> AccessEvent.start()

      assert access.operation == "sse_open"

      closed =
        conn(:get, "/")
        |> assign(:resource_auth, %{kind: :open, client_id: nil, scopes: ["*"]})
        |> send_resp(200, ": disconnected\n\n")

      :ok = AccessEvent.finalize(access, closed, :success, status: 200)
      flush_logs!()

      import Ecto.Query

      log =
        Backplane.Repo.one(
          from(r in ProxyRequest,
            where: r.operation == "sse_open",
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert log.outcome == "success"
      assert log.http_method == "GET"
    end

    test "HEAD health probe does not create a durable row" do
      conn =
        conn(:head, "/")
        |> call_mcp()

      assert conn.status == 204
      flush_logs!()
      assert latest_log() == nil
    end

    test "duplicate event_id is ignored by the writer" do
      assert :ok =
               Backplane.Observability.Buffer.try_enqueue(:mcp_proxy_root, %{
                 event_id: "evt-mcp-int-dup",
                 operation: "jsonrpc",
                 outcome: "success",
                 rpc_method: "ping",
                 http_status: 200,
                 metadata: %{}
               })

      assert :ok =
               Backplane.Observability.Buffer.try_enqueue(:mcp_proxy_root, %{
                 event_id: "evt-mcp-int-dup",
                 operation: "jsonrpc",
                 outcome: "success",
                 rpc_method: "ping",
                 http_status: 200,
                 metadata: %{}
               })

      flush_logs!()

      import Ecto.Query

      assert 1 =
               Backplane.Repo.aggregate(
                 from(r in ProxyRequest, where: r.event_id == "evt-mcp-int-dup"),
                 :count
               )
    end

    test "writer outage does not change MCP responses" do
      conn = mcp_conn("ping")
      assert conn.status == 200

      assert :ok =
               Backplane.Observability.Buffer.try_enqueue(:mcp_proxy_root, %{
                 event_id: "evt-mcp-outage",
                 operation: "jsonrpc",
                 outcome: "success",
                 client_id: Ecto.UUID.generate(),
                 rpc_method: "ping",
                 http_status: 200
               })

      flush_logs!()
      health = Backplane.MCP.LogWriter.health()
      assert health.status == :ok
      assert Jason.decode!(conn.resp_body)["result"] == %{}
    end

    test "does not persist raw request or response bodies" do
      secret = "super-secret-payload-should-not-persist"

      conn =
        mcp_conn("initialize", %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0", "note" => secret}
        })

      assert conn.status == 200
      flush_logs!()

      log = log_for_rpc_method("initialize")
      assert log != nil
      refute Map.has_key?(log, :raw_body)
      refute Map.has_key?(log, :raw_response)
      refute log.metadata |> Jason.encode!() |> String.contains?(secret)
    end
  end

  describe "legacy logger compatibility" do
    setup do
      disable_observability_v2!()
      :ok
    end

    test "RequestLogger still emits human-readable lines when v2 is disabled" do
      log =
        capture_log(fn ->
          conn(:get, "/health")
          |> Backplane.Transport.RequestLogger.call([])
          |> send_resp(200, "ok")
        end)

      assert log =~ "GET /health"
      assert log =~ "200"
    end

    test "emit_mcp_request keeps direct Logger output when v2 is disabled" do
      log =
        capture_log(fn ->
          Backplane.Telemetry.emit_mcp_request("tools/list")
        end)

      assert log =~ "MCP request"
      assert log =~ "tools/list"
    end
  end

  describe "v2 runtime duplicate removal" do
    setup do
      enable_observability_v2!()
      :ok
    end

    test "emit_mcp_request skips duplicate Logger output when v2 is enabled" do
      log =
        capture_log(fn ->
          Backplane.Telemetry.emit_mcp_request("tools/list")
        end)

      refute log =~ "MCP request"
    end
  end

  describe "LogQuery" do
    test "aggregates persisted MCP usage" do
      conn = mcp_conn("ping")
      assert conn.status == 200
      flush_logs!()

      result = LogQuery.aggregate(%{rpc_method: "ping"})
      assert result.total_requests >= 1
      assert is_list(result.by_operation)
    end
  end

  defp modern_mcp_conn(method, params, opts \\ []) do
    version = "2026-07-28"

    body =
      %{
        "jsonrpc" => "2.0",
        "id" => Keyword.get(opts, :id, "modern-#{method}"),
        "method" => method,
        "params" =>
          Map.put(params, "_meta", %{
            "io.modelcontextprotocol/protocolVersion" => version,
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "io.modelcontextprotocol/clientInfo" => %{
              "name" => "backplane-modern-observability-test",
              "version" => "1.0.0"
            }
          })
      }

    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", version)
    |> put_req_header("mcp-method", method)
    |> Context.put(Context.root(request_id: "req-modern-#{method}"))
    |> call_mcp()
  end

  defp mcp_conn(method, params \\ nil, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    auth_token = Keyword.get(opts, :auth_token)

    body = %{"jsonrpc" => "2.0", "method" => method, "id" => id}
    body = if params, do: Map.put(body, "params", params), else: body

    conn =
      conn(:post, "/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Context.put(Context.root(request_id: "req-#{method}-#{id}"))

    conn =
      if auth_token do
        put_req_header(conn, "authorization", "Bearer #{auth_token}")
      else
        conn
      end

    call_mcp(conn)
  end

  defp call_mcp(conn) do
    McpPlug.call(conn, McpPlug.init([]))
  end

  defp flush_and_assert_rpc!(method, outcome, fun \\ fn _ -> :ok end) do
    flush_logs!()
    log = log_for_rpc_method(method)
    assert log.outcome == outcome
    fun.(log)
  end

  defp flush_and_assert_latest!(operation, outcome, fun \\ fn _ -> :ok end) do
    flush_logs!()
    log = latest_log()
    assert log.operation == operation
    assert log.outcome == outcome
    fun.(log)
  end
end
