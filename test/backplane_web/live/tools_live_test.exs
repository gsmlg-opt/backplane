defmodule BackplaneWeb.ToolsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders tools page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/tools")

    assert html =~ "Tools"
    assert html =~ "Search tools"
  end

  test "displays registered tools", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/tools")

    # There should be native tools registered
    assert has_element?(view, "h1", "Tools")
  end
end
