defmodule BackplaneWeb.ProjectsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders projects page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/projects")

    assert html =~ "Projects"
    assert html =~ "New Project"
  end
end
