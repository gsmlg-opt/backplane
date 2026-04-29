defmodule BackplaneWeb.ManagedLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Math.Config

  test "renders math in managed services", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})

    {:ok, _view, html} = live(conn, "/admin/hub/managed")

    assert html =~ "Managed Services"
    assert html =~ "Math"
    assert html =~ "math::"
    assert html =~ "math::evaluate"
  end

  test "toggles math service through math config", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})
    {:ok, view, _html} = live(conn, "/admin/hub/managed")

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
