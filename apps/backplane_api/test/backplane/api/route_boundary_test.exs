defmodule Backplane.Api.RouteBoundaryTest do
  use Backplane.Api.ConnCase, async: false

  test "serves public home page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "One public surface for agents, tools, and model traffic"
  end

  test "does not serve admin routes", %{conn: conn} do
    assert get(conn, "/dashboard/overview") |> response(404)
    assert get(conn, "/admin/dashboard/overview") |> response(404)
  end

  test "routes health through API endpoint", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200)["status"] in ["ok", "healthy"]
  end

  test "does not serve retired /api-prefixed public routes", %{conn: conn} do
    assert post(conn, "/api/mcp", %{}) |> response(404)
    assert get(conn, "/api/v1/models") |> response(404)
    assert post(conn, "/api/anthropic/v1/messages", %{}) |> response(404)
    assert get(conn, "/api/skills") |> response(404)
    assert get(conn, "/api/host-agent/skills/repo-review/download") |> response(404)
  end
end
