defmodule BackplaneWeb.DashboardLiveTest do
  use Backplane.LiveCase

  test "renders dashboard page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/dashboard/overview")

    assert html =~ "Dashboard"
    assert html =~ "Total Tools"
    assert html =~ "Skills"
    assert html =~ "Upstreams"
    assert html =~ ~s(href="/admin/dashboard/overview")
    assert html =~ ~s(href="/admin/dashboard/usage/llm")
    assert html =~ ~s(href="/admin/dashboard/usage/mcp")
    assert html =~ ~s(href="/admin/llama/providers")
    assert html =~ ~s(href="/admin/mcp/managed")
    assert html =~ ~s(href="/admin/skills")
    assert html =~ ~s(href="/admin/system/clients")
    assert html =~ "theme-controller-dropdown"
    assert html =~ ~s(phx-hook="ThemeSwitcher")
    assert has_element?(view, "h1", "Dashboard")
  end

  test "displays stat cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/overview")

    assert has_element?(view, "dt", "Total Tools")
    assert has_element?(view, "dt", "Native Tools")
    assert has_element?(view, "dt", "Upstream Tools")
    assert has_element?(view, "dt", "Skills")
  end

  test "shows quick action buttons", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/overview")

    assert html =~ "Reconnect Degraded"
  end

  test "admin entry redirects to dashboard overview", %{conn: conn} do
    conn = get(conn, "/admin")

    assert redirected_to(conn) == "/admin/dashboard/overview"
  end
end
