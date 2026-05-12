defmodule BackplaneWeb.SkillLiveTest do
  use Backplane.LiveCase

  test "renders blank skill page inside admin shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/skill")

    assert html =~ "Skill"
    assert html =~ ~s(href="/admin/skill")
    assert html =~ ~s(href="/admin/dashboard/overview")
    refute html =~ "Add Skill"
  end
end
