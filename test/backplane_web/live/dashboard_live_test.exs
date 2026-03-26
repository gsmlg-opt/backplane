defmodule BackplaneWeb.DashboardLiveTest do
  use Backplane.LiveCase

  test "renders dashboard page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin")

    assert html =~ "Dashboard"
    assert html =~ "Total Tools"
    assert html =~ "Skills"
    assert html =~ "Upstreams"
    assert has_element?(view, "h1", "Dashboard")
  end

  test "displays stat cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")

    assert has_element?(view, "dt", "Total Tools")
    assert has_element?(view, "dt", "Native Tools")
    assert has_element?(view, "dt", "Upstream Tools")
    assert has_element?(view, "dt", "Skills")
  end
end
