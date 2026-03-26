defmodule BackplaneWeb.ProjectsLiveTest do
  use Backplane.LiveCase

  test "renders projects page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/projects")

    assert html =~ "Projects"
    assert html =~ "New Project"
  end

  test "can open new project form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/projects")

    html = view |> element("button", "New Project") |> render_click()
    assert html =~ "Project ID"
    assert html =~ "Repository URL"
    assert html =~ "Branch/Ref"
  end

  test "can cancel new project form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/projects")

    view |> element("button", "New Project") |> render_click()
    html = view |> element("button", "Cancel") |> render_click()
    refute html =~ "Project ID"
  end
end
