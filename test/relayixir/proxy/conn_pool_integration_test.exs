defmodule Relayixir.Proxy.ConnPoolIntegrationTest do
  use ExUnit.Case

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @moduletag :integration

  setup do
    {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    RouteConfig.put_routes([
      %{host_match: "*", path_prefix: "/", upstream_name: "pool_backend"}
    ])

    UpstreamConfig.put_upstreams(%{
      "pool_backend" => %{
        scheme: :http,
        host: "127.0.0.1",
        port: port,
        pool_size: 5
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

  test "proxies GET /ok with pooling enabled" do
    conn =
      Plug.Test.conn(:get, "http://localhost/ok")
      |> Relayixir.Router.call(Relayixir.Router.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "OK"
  end

  test "second request can reuse a pooled connection" do
    # First request — opens a fresh connection, returns it to pool
    conn1 =
      Plug.Test.conn(:get, "http://localhost/ok")
      |> Relayixir.Router.call(Relayixir.Router.init([]))

    assert conn1.status == 200

    # Second request — should checkout from pool
    conn2 =
      Plug.Test.conn(:get, "http://localhost/ok")
      |> Relayixir.Router.call(Relayixir.Router.init([]))

    assert conn2.status == 200
  end

  test "pooling works with POST and body" do
    conn =
      Plug.Test.conn(:post, "http://localhost/echo", "pooled body")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Relayixir.Router.call(Relayixir.Router.init([]))

    assert conn.status == 200
    assert conn.resp_body == "pooled body"
  end

  test "pooling works with content-length responses" do
    conn =
      Plug.Test.conn(:get, "http://localhost/with-content-length")
      |> Relayixir.Router.call(Relayixir.Router.init([]))

    assert conn.status == 200
    assert conn.resp_body == "Hello, World!"
  end
end
