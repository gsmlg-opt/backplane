defmodule BackplaneWeb.EmbeddingLiveTest do
  use Backplane.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    credential = "embedding-cred-#{System.unique_integer([:positive])}"
    {:ok, _credential} = Credentials.store(credential, "sk-test", "llm")
    :ok = Settings.set("memory.embed_model", nil)

    {:ok, credential: credential}
  end

  test "renders the llama embedding menu page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/llama/embedding")

    assert html =~ "Embedding"
    assert html =~ ~s(href="/admin/llama/providers")
    assert html =~ ~s(href="/admin/llama/model-aliases")
    assert html =~ ~s(href="/admin/llama/embedding")
    assert html =~ ~s(aria-current="page")
  end

  test "lists openai provider models and saves the selected embedding model", %{
    conn: conn,
    credential: credential
  } do
    {provider, _api, model} = create_embedding_model(credential)
    model_id = "#{provider.name}/#{model.model}"

    {:ok, view, html} = live(conn, "/admin/llama/embedding")

    assert html =~ model_id
    assert html =~ ~s(href="/admin/llama/providers/#{provider.id}")

    html =
      view
      |> form("#embedding-model-form", %{"embedding" => %{"model" => model_id}})
      |> render_submit()

    assert html =~ "Embedding model saved"
    assert Settings.get("memory.embed_model") == model_id
  end

  test "keeps unavailable provider models out of the picker", %{
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
    {:ok, provider} =
      Provider.create(%{
        name: "embedding-openai",
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
        model: "text-embedding-3-small",
        display_name: "Text Embedding 3 Small"
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    {Repo.get!(Provider, provider.id), api, model}
  end
end
