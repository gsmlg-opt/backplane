defmodule BackplaneWeb.UpstreamsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders upstreams page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/upstreams")

    assert html =~ "Upstream MCP Servers"
  end
end
