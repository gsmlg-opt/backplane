defmodule BackplaneWeb.GitProvidersLiveTest do
  use Backplane.LiveCase, async: true

  test "renders git providers page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/git")

    assert html =~ "Git Providers"
  end
end
