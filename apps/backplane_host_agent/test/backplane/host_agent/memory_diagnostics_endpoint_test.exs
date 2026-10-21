defmodule Backplane.HostAgent.MemoryDiagnosticsEndpointTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Backplane.HostAgent.MemoryRouter

  test "diagnostics reject nonloopback peers regardless of forwarded headers" do
    conn =
      conn(:post, "/memory/diagnostics", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> Map.put(:remote_ip, {192, 0, 2, 1})
      |> MemoryRouter.call(MemoryRouter.init([]))

    assert conn.status == 403

    assert Jason.decode!(conn.resp_body) == %{
             "ok" => false,
             "error" => "loopback diagnostics only"
           }
  end

  test "diagnostics accept only bounded valid requests and GET is unsupported" do
    for peer <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      conn =
        conn(:post, "/memory/diagnostics", "{}")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, peer)
        |> MemoryRouter.call(MemoryRouter.init([]))

      assert conn.status == 400
      refute conn.resp_body =~ "storage"
    end

    conn = conn(:get, "/memory/diagnostics") |> MemoryRouter.call(MemoryRouter.init([]))
    assert conn.status == 404
  end
end
