defmodule Relayixir.Proxy.HttpPlugErrorCallbackTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Relayixir.Proxy.HttpPlug

  test "uses a protocol error callback only before a response starts" do
    callback = fn conn, reason -> send_resp(conn, 599, inspect(reason)) end

    assert %{status: 599, resp_body: ":upstream_timeout"} =
             HttpPlug.handle_proxy_error(conn(:get, "/"), :upstream_timeout,
               on_proxy_error: callback
             )

    chunked = conn(:get, "/") |> send_chunked(200)

    assert HttpPlug.handle_proxy_error(chunked, :upstream_timeout,
             on_proxy_error: fn _conn, _reason ->
               flunk("must not render after streaming starts")
             end
           ) == chunked
  end
end
