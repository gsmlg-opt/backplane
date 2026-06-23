defmodule Backplane.Admin.RouteBoundaryTest do
  use Backplane.Admin.LiveCase, async: false

  test "redirects /admin to the dashboard", %{conn: conn} do
    conn = get(conn, "/admin")

    assert redirected_to(conn) == "/admin/dashboard/overview"
  end

  test "does not serve API routes", %{conn: conn} do
    conn = get(conn, "/api/mcp")

    assert response(conn, 404)
  end
end
