defmodule Backplane.Transport.HealthCheckTest do
  use Backplane.DataCase, async: false
  import Plug.Test

  alias Backplane.Transport.Router

  describe "GET /health" do
    test "returns 200 when all engines healthy" do
      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] in ["ok", "degraded"]
    end

    test "returns 200 with degraded upstreams" do
      # Even with no upstreams connected, health returns 200
      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
    end

    test "includes engine summaries in response" do
      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["engines"])
      assert Map.has_key?(body["engines"], "proxy")
      assert Map.has_key?(body["engines"], "skills")
      assert Map.has_key?(body["engines"], "docs")
    end
  end
end
