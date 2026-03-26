defmodule BackplaneWeb.LogsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders logs page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/logs")

    assert html =~ "Logs"
    assert html =~ "Background Jobs"
    assert html =~ "Tool Calls"
  end
end
