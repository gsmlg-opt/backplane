defmodule Backplane.Transport.PrometheusEndpointTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Backplane.Transport.MetricsPlug

  describe "GET /prometheus" do
    test "returns 200 with text/plain content type" do
      conn =
        conn(:get, "/prometheus")
        |> MetricsPlug.call(MetricsPlug.init([]))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
      assert is_binary(conn.resp_body)
    end

    test "contains expected metric names" do
      conn =
        conn(:get, "/prometheus")
        |> MetricsPlug.call(MetricsPlug.init([]))

      assert conn.resp_body =~ "backplane_tool_calls_total"
      assert conn.resp_body =~ "backplane_tool_call_duration_microseconds"
      assert conn.resp_body =~ "backplane_upstream_status"
      assert conn.resp_body =~ "backplane_cache_hit_ratio"
    end
  end
end
