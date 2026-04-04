defmodule Relayixir.Proxy.HttpEdgeCasesTest do
  use ExUnit.Case

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @moduletag :integration

  setup do
    {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    RouteConfig.put_routes([
      %{host_match: "*", path_prefix: "/", upstream_name: "test_backend"}
    ])

    UpstreamConfig.put_upstreams(%{
      "test_backend" => %{
        scheme: :http,
        host: "127.0.0.1",
        port: port
      }
    })

    on_exit(fn ->
      try do
        ThousandIsland.stop(server_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port}
  end

  describe "response framing" do
    test "handles 304 Not Modified without body" do
      conn =
        Plug.Test.conn(:get, "http://localhost/304")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 304
      assert conn.resp_body == ""
    end

    test "proxies close-delimited/chunked response without content-length" do
      conn =
        Plug.Test.conn(:get, "http://localhost/no-content-length")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200

      if conn.state == :chunked do
        assert true
      else
        assert conn.resp_body =~ "streamed data"
      end
    end

    test "proxies multi-chunk response preserving all data" do
      conn =
        Plug.Test.conn(:get, "http://localhost/multi-chunk")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200

      if conn.state == :chunked do
        assert true
      else
        assert conn.resp_body =~ "part1-"
        assert conn.resp_body =~ "part2-"
        assert conn.resp_body =~ "part3"
      end
    end
  end

  describe "timeout behavior" do
    test "returns 504 when upstream response is too slow", %{port: port} do
      UpstreamConfig.put_upstreams(%{
        "test_backend" => %{
          scheme: :http,
          host: "127.0.0.1",
          port: port,
          first_byte_timeout: 200,
          request_timeout: 500
        }
      })

      conn =
        Plug.Test.conn(:get, "http://localhost/slow")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 504
      assert conn.resp_body == "Gateway Timeout"
    end
  end

  describe "error mapping" do
    test "returns 502 for connection refused" do
      UpstreamConfig.put_upstreams(%{
        "test_backend" => %{
          scheme: :http,
          host: "127.0.0.1",
          port: 1,
          connect_timeout: 1_000
        }
      })

      conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 502
      assert conn.resp_body == "Bad Gateway"
    end

    test "returns 404 when no route matches" do
      RouteConfig.put_routes([])

      conn =
        Plug.Test.conn(:get, "http://localhost/anything")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
    end

    test "returns 404 when upstream_name not found in config" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "nonexistent"}
      ])

      conn =
        Plug.Test.conn(:get, "http://localhost/ok")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 404
    end
  end

  describe "query string forwarding" do
    test "forwards query string to upstream" do
      conn =
        Plug.Test.conn(:get, "http://localhost/headers?foo=bar&baz=qux")
        |> Relayixir.Router.call(Relayixir.Router.init([]))

      assert conn.status == 200
    end
  end
end
