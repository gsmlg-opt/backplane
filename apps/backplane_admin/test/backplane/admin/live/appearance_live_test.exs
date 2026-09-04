defmodule Backplane.Admin.AppearanceLiveTest do
  use Backplane.Admin.LiveCase

  test "renders appearance page with theme switcher", %{conn: conn} do
    {:ok, view, html} = live(conn, "/system/appearance")

    assert html =~ "Appearance"
    assert html =~ "Choose system theme preference: automatic, light, or dark."
    assert html =~ ~s(phx-hook="ThemeSegmentControl")
    assert has_element?(view, "h1", "Appearance")

    # Segmented buttons
    assert has_element?(view, ~s(#appearance-theme-switcher button[data-theme-value="default"]), "Auto")
    assert has_element?(view, ~s(#appearance-theme-switcher button[data-theme-value="sunshine"]), "Light")
    assert has_element?(view, ~s(#appearance-theme-switcher button[data-theme-value="moonlight"]), "Dark")

    # Sidebar navigation under System shows Appearance link active
    assert has_element?(view, ~s(.admin-sidebar-link[href="/system/appearance"][aria-current="page"]), "Appearance")

    # Appbar does not contain the old theme switcher
    refute has_element?(view, "#admin-theme-switcher")
  end

  test "accepts theme changes without disconnecting", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/appearance")

    assert render_hook(view, "theme_changed", %{"theme" => "sunshine"}) =~ "Appearance"
    assert Process.alive?(view.pid)

    assert render_hook(view, "theme_changed", %{"theme" => "moonlight"}) =~ "Appearance"
    assert Process.alive?(view.pid)

    assert render_hook(view, "theme_changed", %{"theme" => "default"}) =~ "Appearance"
    assert Process.alive?(view.pid)
  end
end
