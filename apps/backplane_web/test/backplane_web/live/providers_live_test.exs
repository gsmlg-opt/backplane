defmodule BackplaneWeb.ProvidersLiveTest do
  use Backplane.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("test-cred", "sk-test", "llm")
    :ok
  end

  defp create_provider_with_apis(name \\ "anthropic-prod") do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        preset_key: "custom",
        credential: "test-cred"
      })

    {:ok, openai_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1",
        model_discovery_path: "/models"
      })

    {:ok, anthropic_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :anthropic,
        base_url: "https://api.example.com/anthropic",
        model_discovery_path: "/v1/models"
      })

    {Provider.get(provider.id), openai_api, anthropic_api}
  end

  describe "index" do
    test "renders provider list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/providers")

      assert html =~ "LLM Providers"
      assert html =~ ~s(href="/admin/providers/new")
      refute html =~ "New Provider"
    end

    test "renders the dedicated new provider page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/providers/new")

      assert html =~ "Add LLM Provider"
      assert html =~ "DeepSeek"
      assert html =~ "Z.ai"
      assert html =~ "MiniMax"
      assert html =~ "OpenAI-compatible API"
      assert html =~ "Anthropic Messages API"
      assert html =~ "provider-name"
      assert html =~ "provider-credential"
      assert html =~ "test-cred (llm)"
      assert html =~ "provider-openai-base-url"
      assert html =~ "provider-anthropic-base-url"
      refute html =~ "provider-api-key"
    end

    test "creates a provider with openai and anthropic API surfaces", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/providers/new")

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "deepseek-test",
          "credential" => "test-cred",
          "base_url" => "https://api.deepseek.com",
          "rpm_limit" => "60",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => "https://api.deepseek.com",
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "true",
          "anthropic_base_url" => "https://api.deepseek.com/anthropic",
          "anthropic_model_discovery_enabled" => "true",
          "anthropic_model_discovery_path" => "/v1/models",
          "anthropic_default_headers" => ~s({"anthropic-version":"2023-06-01"})
        }
      })
      |> render_submit()

      assert_redirect(view, "/admin/providers")

      provider = Repo.get_by!(Provider, name: "deepseek-test")
      assert provider.preset_key == "deepseek"
      assert provider.credential == "test-cred"
      assert provider.rpm_limit == 60

      apis = ProviderApi.list_for_provider(provider.id)

      assert [
               %{api_surface: :anthropic, base_url: "https://api.deepseek.com/anthropic"},
               %{api_surface: :openai, base_url: "https://api.deepseek.com"}
             ] = apis
    end

    test "shows a created provider", %{conn: conn} do
      {provider, _openai_api, _anthropic_api} = create_provider_with_apis()

      {:ok, _view, html} = live(conn, "/admin/providers")

      assert html =~ "LLM Providers"
      assert html =~ "anthropic-prod"
      assert html =~ "Anthropic"
      assert html =~ "https://api.example.com/anthropic"
      assert html =~ ~s(href="/admin/providers/#{provider.id}")
    end

    test "provider detail edits provider and manages models", %{conn: conn} do
      {provider, openai_api, anthropic_api} = create_provider_with_apis()

      {:ok, view, html} = live(conn, "/admin/providers/#{provider.id}")

      assert html =~ "Edit Provider"
      assert html =~ "Add Model"
      assert html =~ "Reload Models"

      view
      |> form("form[phx-submit=save_provider]", %{
        "provider" => %{
          "name" => "anthropic-prod",
          "credential" => "test-cred",
          "enabled" => "true",
          "rpm_limit" => "120",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => "https://api.example.com/v2",
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "true",
          "anthropic_base_url" => "https://api.example.com/anthropic",
          "anthropic_model_discovery_enabled" => "true",
          "anthropic_model_discovery_path" => "/v1/models",
          "anthropic_default_headers" => "{}"
        }
      })
      |> render_submit()

      updated_provider = Repo.get!(Provider, provider.id)
      assert updated_provider.rpm_limit == 120

      updated_openai_api = Repo.get!(ProviderApi, openai_api.id)
      assert updated_openai_api.base_url == "https://api.example.com/v2"

      view
      |> form("form[phx-submit=add_model]", %{
        "model" => %{
          "model" => "provider-model-a",
          "display_name" => "Provider Model A",
          "enabled" => "true",
          "metadata" => "{}",
          "surface_#{openai_api.id}" => "true",
          "surface_#{anthropic_api.id}" => "false"
        }
      })
      |> render_submit()

      model = Repo.get_by!(ProviderModel, provider_id: provider.id, model: "provider-model-a")
      assert model.display_name == "Provider Model A"
      assert model.enabled

      assert %ProviderModelSurface{enabled: true} =
               ProviderModelSurface.get_by_model_and_api(model.id, openai_api.id)

      refute ProviderModelSurface.get_by_model_and_api(model.id, anthropic_api.id)

      view
      |> element("[phx-click='edit_model'][phx-value-id='#{model.id}']", "Edit")
      |> render_click()

      view
      |> form("form[phx-submit=update_model]", %{
        "model" => %{
          "model" => "provider-model-b",
          "display_name" => "Provider Model B",
          "enabled" => "true",
          "metadata" => "{}",
          "surface_#{openai_api.id}" => "true",
          "surface_#{anthropic_api.id}" => "true"
        }
      })
      |> render_submit()

      model = Repo.get!(ProviderModel, model.id)
      assert model.model == "provider-model-b"

      assert %ProviderModelSurface{enabled: true} =
               ProviderModelSurface.get_by_model_and_api(model.id, anthropic_api.id)

      view
      |> element("[phx-click='toggle_model'][phx-value-id='#{model.id}']")
      |> render_click()

      refute Repo.get!(ProviderModel, model.id).enabled

      view
      |> element("[phx-click='delete_model'][phx-value-id='#{model.id}']")
      |> render_click()

      refute Repo.get(ProviderModel, model.id)
    end

    test "does not show soft-deleted providers", %{conn: conn} do
      {:ok, provider} =
        Provider.create(%{
          name: "anthropic-prod",
          preset_key: "custom",
          credential: "test-cred"
        })

      Provider.soft_delete(provider)

      {:ok, _view, html} = live(conn, "/admin/providers")

      refute html =~ "anthropic-prod"
    end
  end
end
