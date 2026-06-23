defmodule Backplane.Admin.DashboardLiveTest do
  use Backplane.Admin.LiveCase

  test "renders dashboard page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/dashboard/overview")

    assert html =~ "Dashboard"
    assert html =~ "Total Tools"
    assert html =~ "Skills"
    assert html =~ "Upstreams"
    assert html =~ ~s(href="/dashboard/overview")
    assert html =~ ~s(href="/dashboard/usage/llm")
    assert html =~ ~s(href="/dashboard/usage/mcp")
    assert html =~ ~s(href="/llama/providers")
    assert html =~ ~s(href="/mcp/managed")
    assert html =~ ~s(href="/memory")
    assert html =~ ~s(href="/skills")
    assert html =~ ~s(href="/system/clients")
    assert html =~ "theme-controller-dropdown"
    assert html =~ ~s(phx-hook="ThemeSwitcher")
    assert has_element?(view, "h1", "Dashboard")
  end

  test "displays stat cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard/overview")

    assert has_element?(view, "dt", "Total Tools")
    assert has_element?(view, "dt", "Native Tools")
    assert has_element?(view, "dt", "Upstream Tools")
    assert has_element?(view, "dt", "Skills")
  end

  test "shows quick action buttons", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/dashboard/overview")

    assert html =~ "Reconnect Degraded"
  end

  test "admin entry redirects to dashboard overview", %{conn: conn} do
    conn = get(conn, "/")

    assert redirected_to(conn) == "/dashboard/overview"
  end
end
