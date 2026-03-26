defmodule BackplaneWeb.LogsLiveTest do
  use Backplane.LiveCase

  test "renders logs page with tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/logs")

    assert html =~ "Logs"
    assert html =~ "Background Jobs"
    assert html =~ "Tool Calls"
  end

  test "can switch between tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/logs")

    # Click tool calls tab
    html = view |> element("button", "Tool Calls") |> render_click()
    assert html =~ "Events appear in real-time"
  end
end
