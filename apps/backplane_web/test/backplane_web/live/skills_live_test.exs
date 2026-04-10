defmodule BackplaneWeb.SkillsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders skills page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/hub/skills")

    assert html =~ "Skills"
    assert html =~ "Search skills"
  end
end
