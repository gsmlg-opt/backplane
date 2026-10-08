defmodule Backplane.Admin.MonitorPlansLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  test "renders the new plan form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/system/monitor/plans/new")

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

    {:ok, view, _html} = live(conn, "/system/monitor/plans/new")

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

    assert_patch(view, "/system/monitor/plans")
    plan = Repo.get_by!(Plan, name: plan_name)

    assert [%{action: "monitor_plan.create", target_id: target_id} = event] =
             Backplane.Admin.Audit.list()

    assert target_id == plan.id
    refute inspect(event) =~ credential_name
    refute inspect(event) =~ "projects/test-project"

    assert %Plan{
             provider: "google_ai",
             credential_name: ^credential_name,
             config: %{"project" => "projects/test-project"}
           } = plan

    tree = view |> render() |> Floki.parse_fragment!()

    assert [trigger] =
             Floki.find(tree, ~s(button[aria-label="Delete #{plan_name}"][command="show-modal"]))

    assert [tooltip_id] = Floki.attribute(trigger, "interestfor")
    assert Floki.attribute(trigger, "aria-describedby") == [tooltip_id]
    assert Floki.attribute(trigger, "title") == ["Delete"]
    assert Floki.attribute(trigger, "phx-click") == []
    assert Floki.attribute(trigger, "phx-value-id") == []
    assert [tooltip] = Floki.find(tree, "##{tooltip_id}[role=tooltip][popover=hint]")
    assert Floki.text(tooltip) |> String.trim() == "Delete"
    assert [dialog_id] = Floki.attribute(trigger, "commandfor")
    assert [action] = Floki.find(tree, "##{dialog_id} [data-dm-confirm-action]")
    assert Floki.attribute(action, "phx-click") == ["delete"]
    assert Floki.attribute(action, "phx-value-id") == [plan.id]
    assert Floki.attribute(action, "interestfor") == []

    view |> element("##{dialog_id} [data-dm-confirm-action]") |> render_click()
    assert Repo.get(Plan, plan.id) == nil
  end

  defp live_form(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:form)
  end
end
