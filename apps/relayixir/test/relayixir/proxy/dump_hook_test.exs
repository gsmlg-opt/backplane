defmodule Relayixir.Proxy.DumpHookTest do
  use ExUnit.Case, async: false

  alias Relayixir.Config.HookConfig
  alias Relayixir.Proxy.{Request, Response}

  setup do
    original_http = HookConfig.get_on_request_complete()
    original_ws = HookConfig.get_on_ws_frame()

    on_exit(fn ->
      HookConfig.put_on_request_complete(original_http)
      HookConfig.put_on_ws_frame(original_ws)
    end)

    :ok
  end

  describe "Request struct" do
    test "from_conn/3 captures method, path, headers, and upstream" do
      conn = Plug.Test.conn(:get, "/api/foo?bar=1")
      headers = [{"x-forwarded-for", "1.2.3.4"}]

      req = Request.from_conn(conn, headers, "backend:4001")

      assert req.method == "GET"
      assert req.path == "/api/foo"
      assert req.query == "bar=1"
      assert req.headers == [{"x-forwarded-for", "1.2.3.4"}]
      assert req.upstream_host == "backend:4001"
    end
  end

  describe "Response struct" do
    test "new/3 captures status, headers, and duration" do
      resp = Response.new(200, [{"content-type", "application/json"}], 42)

      assert resp.status == 200
      assert resp.headers == [{"content-type", "application/json"}]
      assert resp.duration_ms == 42
    end
  end

  describe "HookConfig" do
    test "defaults to nil hook" do
      HookConfig.put_on_request_complete(nil)
      assert HookConfig.get_on_request_complete() == nil
    end

    test "stores and retrieves a hook function" do
      hook = fn _req, _resp -> :called end
      HookConfig.put_on_request_complete(hook)
      assert HookConfig.get_on_request_complete() == hook
    end

    test "defaults to nil ws_frame hook" do
      HookConfig.put_on_ws_frame(nil)
      assert HookConfig.get_on_ws_frame() == nil
    end

    test "stores and retrieves a ws_frame hook function" do
      hook = fn _session_id, _direction, _frame -> :called end
      HookConfig.put_on_ws_frame(hook)
      assert HookConfig.get_on_ws_frame() == hook
    end
  end

  describe "dump hook integration" do
    setup do
      Relayixir.Config.RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      upstream_server =
        start_supervised!({Bandit, plug: Relayixir.TestUpstream, scheme: :http, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream_server)

      Relayixir.Config.UpstreamConfig.put_upstreams(%{
        "test" => %{scheme: :http, host: "localhost", port: port}
      })

      on_exit(fn ->
        Relayixir.Config.RouteConfig.put_routes([])
        Relayixir.Config.UpstreamConfig.put_upstreams(%{})
      end)

      :ok
    end

    test "hook is called after successful proxy with Request and Response structs" do
      test_pid = self()

      HookConfig.put_on_request_complete(fn req, resp ->
        send(test_pid, {:hook_called, req, resp})
      end)

      conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200

      assert_receive {:hook_called, %Request{} = req, %Response{} = resp}, 1000
      assert req.method == "GET"
      assert req.path == "/ok"
      assert resp.status == 200
      assert resp.duration_ms >= 0
    end

    test "hook is not called when not configured" do
      HookConfig.put_on_request_complete(nil)
      test_pid = self()

      conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      refute_receive {:hook_called, _, _}, 100
      # suppress unused warning
      _ = test_pid
    end

    test "hook exceptions do not crash the proxy and are logged" do
      import ExUnit.CaptureLog

      HookConfig.put_on_request_complete(fn _req, _resp ->
        raise "hook exploded"
      end)

      log =
        capture_log(fn ->
          conn =
            Plug.Test.conn(:get, "http://localhost/ok")
            |> Relayixir.Router.call(Relayixir.Router.init([]))

          assert conn.status == 200
        end)

      assert log =~ "on_request_complete hook raised"
      assert log =~ "hook exploded"
    end
  end
end
