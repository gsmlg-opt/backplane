defmodule BackplaneWeb.EmbeddingLiveTest do
  use Backplane.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.Embedding
  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    credential = "embedding-cred-#{System.unique_integer([:positive])}"
    {:ok, _credential} = Credentials.store(credential, "sk-test", "llm")
    :ok = Settings.set("memory.embed_model", nil)

    {:ok, credential: credential}
  end

  test "renders the llama embedding menu page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/llama/embedding")

    assert html =~ "Embedding Providers"
    assert has_element?(view, "#open-embedding-provider-modal", "Add Provider")
    refute has_element?(view, "#embedding-provider-modal")
    assert html =~ "Embedding Models"
    assert html =~ ~s(href="/admin/llama/embedding")
    assert html =~ ~s(aria-current="page")
    refute html =~ "Active Embedding Model"
    refute html =~ "embedding-model-form"
    refute html =~ "Select the LLM provider model"
    refute html =~ "Provider Models"
  end

  test "adds an embedding provider and renders its model in the table", %{
    conn: conn,
    credential: credential
  } do
    {:ok, view, _html} = live(conn, "/admin/llama/embedding")

    html =
      view
      |> element("#open-embedding-provider-modal")
      |> render_click()

    assert html =~ "embedding-provider-modal"
    assert html =~ "Add Embedding Provider"

    html =
      view
      |> form("#embedding-provider-form", %{
        "provider" => %{
          "name" => "embedding-openai",
          "credential" => credential,
          "enabled" => "true",
          "base_url" => "https://api.example.com/v1",
          "default_headers" => "{}",
          "model" => "text-embedding-3-small",
          "display_name" => "Text Embedding 3 Small",
          "model_enabled" => "true",
          "metadata" => "{}"
        }
      })
      |> render_submit()

    assert html =~ "Embedding provider added"
    assert html =~ "embedding-models-table"
    assert html =~ "embedding-openai/text-embedding-3-small"
    assert html =~ "Text Embedding 3 Small"
    assert html =~ "https://api.example.com/v1"
    refute has_element?(view, "#embedding-provider-modal")
    refute html =~ ~s(phx-click="use_model")
    refute html =~ "Active"
    refute html =~ ~s(href="/admin/llama/providers/)
  end

  test "does not expose an active embedding model control", %{
    conn: conn,
    credential: credential
  } do
    model_id = create_embedding_model(credential)
    :ok = Settings.set("memory.embed_model", model_id)

    {:ok, _view, html} = live(conn, "/admin/llama/embedding")

    assert html =~ model_id
    assert html =~ "embedding-models-table"
    refute html =~ "Active Embedding Model"
    refute html =~ "embedding-model-form"
    refute html =~ "Current:"
    refute html =~ "Active"
    refute html =~ ~s(phx-click="use_model")
  end

  test "does not list LLM provider models on the embedding page", %{
    conn: conn,
    credential: credential
  } do
    {:ok, provider} =
      Provider.create(%{
        name: "embedding-disabled",
        credential: credential
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "text-embedding-disabled",
        enabled: false
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    {:ok, _view, html} = live(conn, "/admin/llama/embedding")

    refute html =~ "embedding-disabled/text-embedding-disabled"
  end

  defp create_embedding_model(credential) do
    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-openai",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-3-small",
        "display_name" => "Text Embedding 3 Small",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    "embedding-openai/text-embedding-3-small"
  end
end
