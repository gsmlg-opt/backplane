defmodule Relayixir.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @moduletag :integration

  setup do
    # Save original configs
    original_routes = RouteConfig.get_routes()
    original_upstreams = UpstreamConfig.list_upstreams()

    on_exit(fn ->
      RouteConfig.put_routes(original_routes)
      UpstreamConfig.put_upstreams(original_upstreams)
    end)

    :ok
  end

  describe "route_not_found" do
    test "returns 404 for unmatched routes" do
      RouteConfig.put_routes([])
      UpstreamConfig.put_upstreams(%{})

      conn =
        conn(:get, "/unknown")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end

    test "returns 404 when no routes are configured" do
      RouteConfig.put_routes([])
      UpstreamConfig.put_upstreams(%{})

      conn =
        conn(:get, "/")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
    end

    test "returns 404 when host does not match any route" do
      RouteConfig.put_routes([
        %{host_match: "example.com", path_prefix: "/", upstream_name: "test"}
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{scheme: :http, host: "127.0.0.1", port: 80}
      })

      conn =
        conn(:get, "http://other.com/hello")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "upstream config missing" do
    test "returns 404 when upstream name not found in config" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "nonexistent"}
      ])

      UpstreamConfig.put_upstreams(%{})

      conn =
        conn(:get, "/test")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "HTTP dispatch" do
    setup do
      {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      on_exit(fn ->
        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      %{upstream_port: port}
    end

    test "dispatches GET to HTTP proxy for non-websocket route", %{upstream_port: port} do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: port, scheme: :http}
      })

      conn =
        conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "OK"
    end

    test "dispatches POST requests with body", %{upstream_port: port} do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: port, scheme: :http}
      })

      conn =
        conn(:post, "http://localhost/echo", "hello body")
        |> put_req_header("content-type", "text/plain")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body == "hello body"
    end
  end

  describe "WebSocket dispatch" do
    setup do
      {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      on_exit(fn ->
        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      %{upstream_port: port}
    end

    test "non-upgrade request on websocket-eligible route falls through to HTTP", %{
      upstream_port: port
    } do
      RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/",
          upstream_name: "test",
          websocket: true
        }
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: port, scheme: :http}
      })

      # Regular HTTP request (no upgrade headers) on a websocket-eligible route
      conn =
        conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "OK"
    end

    test "returns 400 for invalid websocket upgrade missing sec-websocket-key" do
      RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/ws",
          upstream_name: "test",
          websocket: true
        }
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: 9999, scheme: :http}
      })

      # Has upgrade and connection headers but missing sec-websocket-key and version
      conn =
        conn(:get, "/ws/chat")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "upgrade")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 400
      assert conn.resp_body == "Invalid WebSocket upgrade request"
    end

    test "returns 400 for websocket upgrade missing sec-websocket-version" do
      RouteConfig.put_routes([
        %{
          host_match: "*",
          path_prefix: "/ws",
          upstream_name: "test",
          websocket: true
        }
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: 9999, scheme: :http}
      })

      conn =
        conn(:get, "/ws/chat")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "upgrade")
        |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 400
    end
  end

  describe "path prefix matching" do
    setup do
      {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      on_exit(fn ->
        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      %{upstream_port: port}
    end

    test "routes match in order with first matching route winning", %{upstream_port: port} do
      # First route listed should match first (order matters)
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/ok", upstream_name: "api_backend"},
        %{host_match: "*", path_prefix: "/", upstream_name: "dead_backend"}
      ])

      UpstreamConfig.put_upstreams(%{
        "api_backend" => %{host: "127.0.0.1", port: port, scheme: :http},
        "dead_backend" => %{host: "127.0.0.1", port: 1, scheme: :http}
      })

      conn =
        conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      # If the first route matched, we get 200 from the real upstream
      # If the second route matched, we'd get 502 from the dead upstream
      assert conn.status == 200
    end
  end

  describe "wildcard host matching" do
    setup do
      {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      on_exit(fn ->
        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      %{upstream_port: port}
    end

    test "wildcard host matches any request", %{upstream_port: port} do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "test"}
      ])

      UpstreamConfig.put_upstreams(%{
        "test" => %{host: "127.0.0.1", port: port, scheme: :http}
      })

      conn =
        conn(:get, "http://any-host.example.com/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
    end
  end

  describe "upstream unreachable" do
    test "returns 502 when upstream connection is refused" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "dead"}
      ])

      UpstreamConfig.put_upstreams(%{
        "dead" => %{host: "127.0.0.1", port: 1, scheme: :http, connect_timeout: 1_000}
      })

      conn =
        conn(:get, "/anything")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 502
      assert conn.resp_body == "Bad Gateway"
    end
  end
end
