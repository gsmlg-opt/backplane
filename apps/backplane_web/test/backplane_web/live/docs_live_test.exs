defmodule BackplaneWeb.DocsLiveTest do
  use Backplane.LiveCase, async: true

  test "renders docs page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/docs")

    assert html =~ "Documentation Projects"
  end
end
