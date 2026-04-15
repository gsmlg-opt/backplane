defmodule BackplaneWeb.SettingsLiveTest do
  use Backplane.LiveCase, async: true

  import Phoenix.LiveViewTest

  describe "credentials tab" do
    test "renders credentials tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings?tab=credentials")
      assert html =~ "Credential Store"
      assert html =~ "Add Credential"
    end

    test "show_add_form opens the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings?tab=credentials")

      html =
        view
        |> element("el-dm-button[phx-click=show_add_form]")
        |> render_click()

      assert html =~ "New Credential"
      assert html =~ "save_credential"
    end

    test "can add a credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings?tab=credentials")

      # Open the form
      view
      |> element("el-dm-button[phx-click=show_add_form]")
      |> render_click()

      # Submit the form
      html =
        view
        |> form("form[phx-submit=save_credential]", %{
          "name" => "test-key",
          "kind" => "llm",
          "secret" => "sk-test-123"
        })
        |> render_submit()

      assert html =~ "test-key"
      refute html =~ "New Credential"
    end
  end
end
