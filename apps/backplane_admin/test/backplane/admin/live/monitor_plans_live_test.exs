defmodule Backplane.Admin.MonitorPlansLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  test "renders the new plan form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/system/monitor/plans/new")

    assert html =~ "New Plan"
    assert html =~ "plan[name]"
    assert html =~ "plan[provider]"
    assert html =~ "plan[credential_name]"
    assert html =~ "plan[config][project]"
    assert html =~ "Google Antigravity"
    refute html =~ "Google Antigravity (Coming Soon)"

    assert %Phoenix.HTML.Form{source: source} = live_form(view)
    assert is_map(source)
    refute match?(%Ecto.Changeset{}, source)
  end

  test "creates a Google Antigravity plan with project config", %{conn: conn} do
    plan_name = "google-antigravity-#{System.unique_integer([:positive])}"
    credential_name = "google-antigravity-cred-#{System.unique_integer([:positive])}"

    {:ok, _credential} = Credentials.store(credential_name, "unused", "service")

    {:ok, view, _html} = live(conn, "/admin/system/monitor/plans/new")

    view
    |> form("form", %{
      "plan" => %{
        "name" => plan_name,
        "provider" => "google_ai",
        "credential_name" => credential_name,
        "config" => %{"project" => "projects/test-project"}
      }
    })
    |> render_submit()

    assert_patch(view, "/admin/system/monitor/plans")

    assert %Plan{
             provider: "google_ai",
             credential_name: ^credential_name,
             config: %{"project" => "projects/test-project"}
           } = Repo.get_by(Plan, name: plan_name)
  end

  defp live_form(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:form)
  end
end
