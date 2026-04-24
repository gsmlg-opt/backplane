defmodule BackplaneWeb.HubLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Math.Config

  test "renders hub page with native math service", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})

    {:ok, _view, html} = live(conn, "/admin/hub")

    assert html =~ "MCP Hub"
    assert html =~ "Math"
    assert html =~ "math::"
    assert html =~ "native"
  end
end
