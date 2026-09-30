defmodule Backplane.Admin.CodexCatalogLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{CodexCatalog, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings.Credentials

  test "renders the Codex catalog policy page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/llama/codex-catalog")

    assert html =~ "Codex Model Catalog"
    assert html =~ "Exposure policy"
    assert html =~ ~s(id="codex-catalog-form")
    assert html =~ "Routable model candidates"
    assert html =~ "No enabled OpenAI Responses models are available."
    assert html =~ "No catalog entries configured."
  end

  test "previews the effective catalog response", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/llama/codex-catalog")

    html = view |> element(~s([phx-click="preview"])) |> render_click()

    assert html =~ "Effective Codex catalog preview"
    assert html =~ "0 models will be published."
    assert html =~ "models"
  end

  test "shows routable candidates and fills the routing target", %{conn: conn} do
    source = create_candidate()
    {:ok, view, html} = live(conn, "/llama/codex-catalog")

    assert html =~ "Routable model candidates"
    assert html =~ source

    html =
      view
      |> element(~s([phx-click="select_candidate"][phx-value-source="#{source}"]))
      |> render_click()

    assert html =~ ~s(id="codex-source-model")
    assert html =~ ~s(value="#{source}")
  end

  test "shows validation errors for an unroutable target", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/llama/codex-catalog")

    html =
      view
      |> form("#codex-catalog-form", %{
        "catalog[public_model_id]" => "invalid-public-id",
        "catalog[source_model]" => "missing-provider/missing-model"
      })
      |> render_submit()

    assert html =~ "must resolve to an enabled OpenAI Responses route"
  end

  test "adds and toggles a catalog entry", %{conn: conn} do
    source = create_candidate()
    {:ok, view, _html} = live(conn, "/llama/codex-catalog")

    html =
      view
      |> form("#codex-catalog-form", %{
        "catalog[public_model_id]" => "selected-candidate",
        "catalog[source_model]" => source,
        "catalog[display_name]" => "Selected Candidate"
      })
      |> render_submit()

    assert html =~ "selected-candidate"
    entry = List.first(CodexCatalog.list())
    refute entry.enabled

    html =
      view
      |> element(~s([phx-click="toggle"][phx-value-id="#{entry.id}"]))
      |> render_click()

    assert html =~ "Exposed"
  end

  defp create_candidate do
    credential = "codex-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "admin-catalog-key", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "admin-catalog-#{System.unique_integer([:positive])}",
        credential: credential,
        preset_key: "custom"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://admin-catalog.example.test/v1",
        native_protocols: [:openai_responses]
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "candidate-model",
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id
      })

    "#{provider.name}/#{model.model}"
  end
end
