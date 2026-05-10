defmodule BackplaneWeb.SettingsLiveTest do
  use Backplane.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{
    AutoModel,
    AutoModelRoute,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  describe "settings tab" do
    setup do
      reset_auto_model_targets()
      reset_custom_model_aliases()
      :ok
    end

    test "renders model alias settings instead of internal service toggles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings")

      assert html =~ "Model Aliases"
      assert html =~ "smart"
      assert html =~ "fast"
      assert html =~ "expert"
      assert html =~ "minimax-m2.7"
      assert html =~ "kimi-k2.6"
      assert html =~ "glm-5.1"

      refute html =~ "services.day.enabled"
      refute html =~ "services.web.enabled"
      refute html =~ "admin.auth_enabled"
      refute html =~ "mcp.auth_required"
    end

    test "renders model aliases in fast, smart, expert order", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings")

      fast_index = index_of!(html, "auto-model-fast-add-form")
      smart_index = index_of!(html, "auto-model-smart-add-form")
      expert_index = index_of!(html, "auto-model-expert-add-form")

      assert fast_index < smart_index
      assert smart_index < expert_index
    end

    test "renders target model picker options from enabled provider models", %{conn: conn} do
      create_provider_models(["fast-model-a"])

      {:ok, _view, html} = live(conn, "/admin/settings")

      assert html =~ ~s(id="auto-model-fast-model")
      assert html =~ ~s(<option value="fast-model-a">)
      refute html =~ ~s(id="auto-model-fast-models")
    end

    test "adds selected model target to alias list", %{conn: conn} do
      {openai_api, [model_id]} = create_provider_models(["fast-model-a"])

      {:ok, view, _html} = live(conn, "/admin/settings")

      html =
        view
        |> form("#auto-model-fast-add-form", %{
          "name" => "fast",
          "model" => model_id
        })
        |> render_submit()

      assert html =~ model_id
      assert AutoModel.configured_model_ids("fast") == [model_id]

      route = AutoModelRoute.get_by_model_and_surface("fast", :openai)

      targets =
        route.targets
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(& &1.provider_model_surface_id)

      expected_targets =
        ProviderModel
        |> Repo.get_by!(provider_id: openai_api.provider_id, model: model_id)
        |> then(&ProviderModelSurface.get_by_model_and_api(&1.id, openai_api.id))
        |> Map.fetch!(:id)

      assert targets == [expected_targets]
    end

    test "removes a model target from the alias list", %{conn: conn} do
      {_openai_api, [model_id]} = create_provider_models(["fast-model-a"])

      {:ok, view, _html} = live(conn, "/admin/settings")

      view
      |> form("#auto-model-fast-add-form", %{
        "name" => "fast",
        "model" => model_id
      })
      |> render_submit()

      html =
        view
        |> element(
          ~s(button[phx-click="remove_auto_model_target"][phx-value-name="fast"][phx-value-model="#{model_id}"])
        )
        |> render_click()

      assert html =~ "No target models selected"
      assert AutoModel.configured_model_ids("fast") == []
    end

    test "renders custom alias form with built-in alias targets", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings")

      assert html =~ ~s(id="custom-model-alias-form")
      assert html =~ ~s(id="custom-model-alias-target")
      assert html =~ ~s(<option value="fast">)
      assert html =~ ~s(<option value="smart">)
      assert html =~ ~s(<option value="expert">)
    end

    test "adds custom alias pointing to a built-in alias", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      html =
        view
        |> form("#custom-model-alias-form", %{
          "alias" => "coding",
          "target" => "expert"
        })
        |> render_submit()

      assert html =~ "coding"
      assert html =~ "expert"
      assert [%{alias: "coding", target: "expert"}] = Backplane.LLM.ModelAlias.list()
    end

    test "removes a custom alias", %{conn: conn} do
      {:ok, _alias} = Backplane.LLM.ModelAlias.put("coding", "smart")

      {:ok, view, _html} = live(conn, "/admin/settings")

      html =
        view
        |> element(~s(button[phx-click="remove_custom_model_alias"][phx-value-alias="coding"]))
        |> render_click()

      assert html =~ "No custom aliases configured"
      assert Backplane.LLM.ModelAlias.list() == []
    end
  end

  defp reset_auto_model_targets do
    :ok = Backplane.Settings.set("llm.auto_models.fast.targets", [])

    :ok =
      Backplane.Settings.set("llm.auto_models.smart.targets", [
        "minimax-m2.7",
        "kimi-k2.6",
        "glm-5.1"
      ])

    :ok = Backplane.Settings.set("llm.auto_models.expert.targets", [])
  end

  defp reset_custom_model_aliases do
    :ok = Backplane.Settings.set("llm.model_aliases.custom", %{})
  end

  defp create_provider_models(model_ids) do
    credential = "settings-llm-#{System.unique_integer([:positive])}"
    Credentials.store(credential, "sk-test", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "settings-provider-#{System.unique_integer([:positive])}",
        credential: credential
      })

    {:ok, openai_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1"
      })

    for model_id <- model_ids do
      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: model_id,
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: openai_api.id,
          enabled: true
        })
    end

    {openai_api, model_ids}
  end

  defp index_of!(html, value) do
    case :binary.match(html, value) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(value)} to be present in rendered HTML")
    end
  end

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
