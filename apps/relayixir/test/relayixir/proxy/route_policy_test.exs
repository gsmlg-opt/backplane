defmodule Relayixir.Proxy.RoutePolicyTest do
  use ExUnit.Case, async: false

  setup do
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

    %{port: port}
  end

  describe "allowed_methods policy" do
    test "allows request when method is in allowed list" do
      Relayixir.Config.RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test", allowed_methods: ["GET"]}
      ])

      conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
    end

    test "returns 405 when method is not in allowed list" do
      Relayixir.Config.RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test", allowed_methods: ["GET"]}
      ])

      conn =
        Plug.Test.conn(:post, "http://localhost/echo")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 405
    end

    test "allows all methods when allowed_methods is nil (default)" do
      Relayixir.Config.RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      conn =
        Plug.Test.conn(:post, "http://localhost/echo")
        |> Map.put(:body_params, %{})
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
    end

    test "method matching is case-insensitive for the config" do
      Relayixir.Config.RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          allowed_methods: ["GET", "POST"]
        }
      ])

      conn =
        Plug.Test.conn(:post, "http://localhost/echo")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
    end

    test "multiple allowed methods are checked correctly" do
      Relayixir.Config.RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          allowed_methods: ["GET", "HEAD"]
        }
      ])

      get_conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert get_conn.status == 200

      post_conn =
        Plug.Test.conn(:post, "http://localhost/echo")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert post_conn.status == 405
    end
  end

  describe "inject_request_headers policy" do
    test "injected headers are forwarded to upstream" do
      Relayixir.Config.RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          inject_request_headers: [{"x-injected", "hello"}]
        }
      ])

      conn =
        Plug.Test.conn(:get, "http://localhost/headers")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "x-injected=hello"
    end

    test "multiple injected headers are all forwarded" do
      Relayixir.Config.RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          inject_request_headers: [
            {"x-tenant", "acme"},
            {"x-env", "production"}
          ]
        }
      ])

      conn =
        Plug.Test.conn(:get, "http://localhost/headers")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "x-tenant=acme"
      assert conn.resp_body =~ "x-env=production"
    end

    test "no extra headers when inject_request_headers is empty (default)" do
      Relayixir.Config.RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      conn =
        Plug.Test.conn(:get, "http://localhost/headers")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      refute conn.resp_body =~ "x-injected"
    end
  end

  describe "combined policy" do
    test "allowed method + injected headers work together" do
      Relayixir.Config.RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          allowed_methods: ["GET"],
          inject_request_headers: [{"x-policy", "enforced"}]
        }
      ])

      # GET passes policy and sees injected header
      get_conn =
        Plug.Test.conn(:get, "http://localhost/headers")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert get_conn.status == 200
      assert get_conn.resp_body =~ "x-policy=enforced"

      # POST is rejected before reaching upstream
      post_conn =
        Plug.Test.conn(:post, "http://localhost/echo")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert post_conn.status == 405
    end
  end
end
