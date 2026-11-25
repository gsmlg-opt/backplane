defmodule Backplane.Admin.ManagedToolDetailLiveTest do
  use Backplane.Admin.LiveCase, async: false

  @day_setting "services.day.enabled"

  setup do
    previous_setting = :ets.lookup(:backplane_settings, @day_setting)
    :ets.insert(:backplane_settings, {@day_setting, true})

    on_exit(fn ->
      :ets.delete(:backplane_settings, @day_setting)

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end
    end)

    :ok
  end

  test "renders and invokes a managed Day tool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mcp/managed/day/tool/now")

    assert html =~ "day::now"
    assert html =~ "Get the current date and time"
    assert html =~ "Input Schema"
    assert html =~ "Test Tool"

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Result"
  end

  test "rejects a detail-page call after Day is disabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/managed/day/tool/now")
    :ets.insert(:backplane_settings, {@day_setting, false})

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Error"
    assert html =~ "day service is disabled"
  end

  test "redirects removed Skills tool details", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/mcp/managed"}}} =
             live(conn, "/mcp/managed/skill/tool/list")
  end

  test "reports malformed and duplicate JSON arguments without crashing the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/managed/day/tool/now")

    for arguments <- ["{", ~s({"limit":1,"limit":2})] do
      html =
        view
        |> form("#tool-test-form", %{"test" => %{"arguments" => arguments}})
        |> render_submit()

      assert html =~ "Invalid JSON:"
      assert has_element?(view, "#tool-test-form")
    end
  end
end
