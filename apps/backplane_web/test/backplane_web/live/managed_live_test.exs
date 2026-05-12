defmodule BackplaneWeb.ManagedLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Math.Config

  test "renders math in managed services", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})

    {:ok, _view, html} = live(conn, "/admin/mcp/managed")

    assert html =~ "Managed Services"
    assert html =~ "Math"
    assert html =~ "math::"
    assert html =~ "math::evaluate"
    assert html =~ ~s(href="/admin/mcp/managed/math")
  end

  test "renders web search in managed services", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/mcp/managed")

    assert html =~ "Managed Services"
    assert html =~ "Web Search"
    assert html =~ "web_search::"
    assert html =~ "web_search::search"
    assert html =~ ~s(href="/admin/mcp/managed/web_search")
  end

  test "links other managed services to debug pages", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/mcp/managed")

    assert html =~ ~s(href="/admin/mcp/managed/day")
    assert html =~ ~s(href="/admin/mcp/managed/web")
    assert html =~ ~s(href="/admin/mcp/managed/math")
  end

  test "toggles web search service through settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/mcp/managed")

    view
    |> element("[phx-value-prefix='web_search']", "Disable")
    |> render_click()

    refute Backplane.Services.WebSearch.enabled?()

    view
    |> element("[phx-value-prefix='web_search']", "Enable")
    |> render_click()

    assert Backplane.Services.WebSearch.enabled?()
  end

  test "toggles math service through math config", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})
    {:ok, view, _html} = live(conn, "/admin/mcp/managed")

    view
    |> element("[phx-value-prefix='math']", "Disable")
    |> render_click()

    refute Config.get(:enabled)

    view
    |> element("[phx-value-prefix='math']", "Enable")
    |> render_click()

    assert Config.get(:enabled)
  end
end
