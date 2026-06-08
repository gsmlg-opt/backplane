defmodule BackplaneWeb.MonitorPlansLiveTest do
  use Backplane.LiveCase, async: false

  test "renders the new plan form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/system/monitor/plans/new")

    assert html =~ "New Plan"
    assert html =~ "plan[name]"
    assert html =~ "plan[provider]"
    assert html =~ "plan[credential_name]"

    assert %Phoenix.HTML.Form{source: source} = live_form(view)
    assert is_map(source)
    refute match?(%Ecto.Changeset{}, source)
  end

  defp live_form(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:form)
  end
end
