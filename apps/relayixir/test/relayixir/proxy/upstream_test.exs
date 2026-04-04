defmodule Relayixir.Proxy.UpstreamTest do
  use ExUnit.Case

  alias Relayixir.Proxy.Upstream
  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  setup do
    # Clear configs before each test
    RouteConfig.put_routes([])
    UpstreamConfig.put_upstreams(%{})
    :ok
  end

  describe "resolve/1" do
    test "resolves a matching route and upstream" do
      RouteConfig.put_routes([
        %{host_match: "example.com", path_prefix: "/api", upstream_name: "api_backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "api_backend" => %{
          scheme: :http,
          host: "backend.local",
          port: 8080
        }
      })

      conn = Plug.Test.conn(:get, "http://example.com/api/users")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.host == "backend.local"
      assert upstream.port == 8080
      assert upstream.scheme == :http
    end

    test "returns error when no route matches" do
      RouteConfig.put_routes([
        %{host_match: "example.com", path_prefix: "/api", upstream_name: "api_backend"}
      ])

      conn = Plug.Test.conn(:get, "http://other.com/test")
      assert {:error, :route_not_found} = Upstream.resolve(conn)
    end

    test "returns error when upstream not configured" do
      RouteConfig.put_routes([
        %{host_match: "example.com", path_prefix: "/api", upstream_name: "missing_backend"}
      ])

      UpstreamConfig.put_upstreams(%{})

      conn = Plug.Test.conn(:get, "http://example.com/api/users")
      assert {:error, :route_not_found} = Upstream.resolve(conn)
    end

    test "resolves wildcard host route" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "default_backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "default_backend" => %{
          scheme: :http,
          host: "default.local",
          port: 80
        }
      })

      conn = Plug.Test.conn(:get, "http://anything.com/some/path")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.host == "default.local"
    end

    test "builds upstream with websocket flag from route" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/ws", upstream_name: "ws_backend", websocket: true}
      ])

      UpstreamConfig.put_upstreams(%{
        "ws_backend" => %{
          scheme: :http,
          host: "ws.local",
          port: 9090
        }
      })

      conn = Plug.Test.conn(:get, "http://example.com/ws/connect")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.websocket? == true
    end

    test "uses route-level timeout overrides" do
      RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "backend",
          timeouts: %{request_timeout: 120_000}
        }
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{
          scheme: :http,
          host: "backend.local",
          port: 80,
          connect_timeout: 10_000
        }
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.request_timeout == 120_000
      assert upstream.connect_timeout == 10_000
    end

    test "uses default timeouts when not specified" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{scheme: :http, host: "backend.local", port: 80}
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.request_timeout == 60_000
      assert upstream.connect_timeout == 5_000
      assert upstream.first_byte_timeout == 30_000
    end

    test "uses max_response_body_size from upstream config" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{
          scheme: :http,
          host: "backend.local",
          port: 80,
          max_response_body_size: 1024
        }
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.max_response_body_size == 1024
    end

    test "uses max_request_body_size from upstream config" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{
          scheme: :http,
          host: "backend.local",
          port: 80,
          max_request_body_size: 2048
        }
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.max_request_body_size == 2048
    end

    test "uses default body size limits when not specified" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{scheme: :http, host: "backend.local", port: 80}
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.max_response_body_size == 10_485_760
      assert upstream.max_request_body_size == 8_388_608
    end

    test "uses pool_size from upstream config" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{scheme: :http, host: "backend.local", port: 80, pool_size: 5}
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.pool_size == 5
    end

    test "uses host_forward_mode from route" do
      RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "backend",
          host_forward_mode: :rewrite_to_upstream
        }
      ])

      UpstreamConfig.put_upstreams(%{
        "backend" => %{scheme: :http, host: "backend.local", port: 80}
      })

      conn = Plug.Test.conn(:get, "http://example.com/test")
      assert {:ok, upstream} = Upstream.resolve(conn)
      assert upstream.host_forward_mode == :rewrite_to_upstream
    end
  end
end
