defmodule Backplane.Admin.LogsLiveTest do
  use Backplane.Admin.LiveCase

  test "renders logs page with tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/system/logs")

    assert html =~ "Logs"
    assert html =~ "Background Jobs"
    assert html =~ "Tool Calls"
  end

  test "can switch between tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/logs")

    html = view |> element("el-dm-button", "Tool Calls") |> render_click()
    assert html =~ "Events appear in real-time"
  end
end
