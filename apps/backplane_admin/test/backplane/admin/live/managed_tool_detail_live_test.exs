defmodule Backplane.Admin.ManagedToolDetailLiveTest do
  use Backplane.Admin.LiveCase, async: false

  @skills_setting "services.skill.enabled"

  setup do
    previous_setting = :ets.lookup(:backplane_settings, @skills_setting)
    :ets.insert(:backplane_settings, {@skills_setting, true})

    on_exit(fn ->
      :ets.delete(:backplane_settings, @skills_setting)

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end
    end)

    :ok
  end

  test "renders and invokes a managed Skills tool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mcp/managed/skill/tool/list")

    assert html =~ "skill::list"
    assert html =~ "List all available skills"
    assert html =~ "Input Schema"
    assert html =~ "Test Tool"

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Result"
  end

  test "rejects a detail-page call after Skills is disabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/managed/skill/tool/list")
    :ets.insert(:backplane_settings, {@skills_setting, false})

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Error"
    assert html =~ "Skills service is disabled"
  end
end
