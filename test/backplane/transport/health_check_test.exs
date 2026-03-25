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

  describe "check/0 direct" do
    alias Backplane.Transport.HealthCheck

    test "returns status ok when no upstreams are degraded" do
      result = HealthCheck.check()
      assert result.status in ["ok", "degraded"]
      assert is_map(result.engines)
    end

    test "returns proxy engine with total_tools count" do
      result = HealthCheck.check()
      assert is_integer(result.engines.proxy.total_tools)
      assert result.engines.proxy.total_tools >= 0
    end

    test "returns skills engine with total count" do
      result = HealthCheck.check()
      assert is_integer(result.engines.skills.total)
    end

    test "returns docs engine with project and chunk counts" do
      result = HealthCheck.check()
      assert is_integer(result.engines.docs.projects)
      assert is_integer(result.engines.docs.chunks)
    end

    test "returns git engine with ok status" do
      result = HealthCheck.check()
      assert result.engines.git.status == "ok"
    end

    test "returns upstreams list in proxy engine" do
      result = HealthCheck.check()
      assert is_list(result.engines.proxy.upstreams)
    end
  end
end
