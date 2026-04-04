defmodule Relayixir.Config.ReloadTest do
  use ExUnit.Case, async: false

  alias Relayixir.Config.{RouteConfig, UpstreamConfig, HookConfig}

  setup do
    original_routes = RouteConfig.get_routes()
    original_upstreams = UpstreamConfig.list_upstreams()
    original_http_hook = HookConfig.get_on_request_complete()
    original_ws_hook = HookConfig.get_on_ws_frame()

    on_exit(fn ->
      RouteConfig.put_routes(original_routes)
      UpstreamConfig.put_upstreams(original_upstreams)
      HookConfig.put_on_request_complete(original_http_hook)
      HookConfig.put_on_ws_frame(original_ws_hook)
    end)

    :ok
  end

  describe "Relayixir.load/1" do
    test "loads routes and upstreams atomically" do
      routes = [%{host_match: "*", path_prefix: "/api", upstream_name: "backend"}]
      upstreams = %{"backend" => %{scheme: :http, host: "localhost", port: 4001}}

      assert :ok = Relayixir.load(routes: routes, upstreams: upstreams)

      assert RouteConfig.get_routes() == routes
      assert UpstreamConfig.list_upstreams() == upstreams
    end

    test "partial load updates only provided keys" do
      RouteConfig.put_routes([%{host_match: "*", path_prefix: "/", upstream_name: "a"}])
      UpstreamConfig.put_upstreams(%{"a" => %{host: "old", port: 80}})

      new_upstreams = %{"b" => %{host: "new", port: 443}}
      assert :ok = Relayixir.load(upstreams: new_upstreams)

      # Routes unchanged
      assert [%{upstream_name: "a"}] = RouteConfig.get_routes()
      # Upstreams replaced
      assert UpstreamConfig.list_upstreams() == new_upstreams
    end

    test "loads hooks via load/1" do
      hook = fn _req, _resp -> :ok end
      ws_hook = fn _sid, _dir, _frame -> :ok end

      assert :ok = Relayixir.load(hooks: [on_request_complete: hook, on_ws_frame: ws_hook])

      assert HookConfig.get_on_request_complete() == hook
      assert HookConfig.get_on_ws_frame() == ws_hook
    end

    test "partial hook update does not clear other hooks" do
      hook = fn _req, _resp -> :ok end
      ws_hook = fn _sid, _dir, _frame -> :ok end

      Relayixir.load(hooks: [on_request_complete: hook, on_ws_frame: ws_hook])

      # Update only the ws hook — should not clear the http hook
      new_ws_hook = fn _sid, _dir, _frame -> :updated end
      Relayixir.load(hooks: [on_ws_frame: new_ws_hook])

      assert HookConfig.get_on_request_complete() == hook
      assert HookConfig.get_on_ws_frame() == new_ws_hook
    end

    test "load with empty list is a no-op" do
      original_routes = RouteConfig.get_routes()
      assert :ok = Relayixir.load([])
      assert RouteConfig.get_routes() == original_routes
    end
  end

  describe "Relayixir.reload/0" do
    test "loads from application env" do
      routes = [%{host_match: "example.com", path_prefix: "/", upstream_name: "srv"}]
      upstreams = %{"srv" => %{scheme: :https, host: "example.com", port: 443}}

      Application.put_env(:relayixir, :routes, routes)
      Application.put_env(:relayixir, :upstreams, upstreams)

      on_exit(fn ->
        Application.delete_env(:relayixir, :routes)
        Application.delete_env(:relayixir, :upstreams)
      end)

      assert :ok = Relayixir.reload()

      assert RouteConfig.get_routes() == routes
      assert UpstreamConfig.list_upstreams() == upstreams
    end

    test "reload with no app env sets empty config" do
      Application.delete_env(:relayixir, :routes)
      Application.delete_env(:relayixir, :upstreams)

      assert :ok = Relayixir.reload()

      assert RouteConfig.get_routes() == []
      assert UpstreamConfig.list_upstreams() == %{}
    end
  end
end
