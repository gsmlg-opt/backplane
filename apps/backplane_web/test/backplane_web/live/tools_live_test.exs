defmodule BackplaneWeb.ToolsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders tools page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/hub/tools")

    assert html =~ "Tools"
    assert html =~ "Search tools"
  end

  test "displays registered tools", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/hub/tools")

    assert has_element?(view, "h1", "Tools")
  end

  test "has search functionality", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/hub/tools")

    assert has_element?(view, "input[placeholder='Search tools...']")
  end
end
