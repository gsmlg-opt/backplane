defmodule BackplaneWeb.ProvidersLiveTest do
  use Backplane.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Backplane.LLM.Provider

  describe "index" do
    test "renders provider list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/providers")

      assert html =~ "LLM Providers"
    end

    test "shows a created provider", %{conn: conn} do
      {:ok, _} =
        Provider.create(%{
          name: "anthropic-prod",
          api_type: :anthropic,
          api_url: "https://api.anthropic.com",
          api_key: "sk-test",
          models: ["claude-sonnet-4-20250514"]
        })

      {:ok, _view, html} = live(conn, "/admin/providers")

      assert html =~ "LLM Providers"
      assert html =~ "anthropic-prod"
    end

    test "does not show soft-deleted providers", %{conn: conn} do
      {:ok, provider} =
        Provider.create(%{
          name: "anthropic-prod",
          api_type: :anthropic,
          api_url: "https://api.anthropic.com",
          api_key: "sk-test",
          models: ["claude-sonnet-4-20250514"]
        })

      Provider.soft_delete(provider)

      {:ok, _view, html} = live(conn, "/admin/providers")

      refute html =~ "anthropic-prod"
    end
  end
end
