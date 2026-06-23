defmodule Backplane.Api.RouteBoundaryTest do
  use Backplane.Api.ConnCase, async: false

  test "serves public home page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Private gateway for MCP tools and LLM APIs"
  end

  test "does not serve admin routes", %{conn: conn} do
    conn = get(conn, "/admin/dashboard/overview")

    assert response(conn, 404)
  end

  test "routes health through API endpoint", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200)["status"] in ["ok", "healthy"]
  end
end
