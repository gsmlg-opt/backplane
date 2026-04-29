defmodule BackplaneWeb.HubLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Math.Config

  test "renders hub page with managed math service", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})

    {:ok, _view, html} = live(conn, "/admin/hub")

    assert html =~ "MCP Hub"
    assert html =~ "math"
    assert html =~ "math::"
    assert html =~ "managed"
  end

  test "does not list disabled managed services", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: false})

    {:ok, _view, html} = live(conn, "/admin/hub")

    assert html =~ "MCP Hub"
    refute html =~ "math::"
  end
end
