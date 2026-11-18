defmodule Backplane.Admin.EmbeddingLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.Embedding
  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Settings.Credentials

  setup do
    credential = "embedding-cred-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "sk-private-embedding", "llm")
    %{credential: credential}
  end

  test "Embeddings configures an API separately from provider connections", %{
    conn: conn,
    credential: credential
  } do
    {:ok, provider} = Provider.create(%{name: "platform-embedding", credential: credential})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1",
        native_protocols: []
      })

    {:ok, view, html} = live(conn, "/llama/embedding")
    assert html =~ "POST /v1/embeddings"
    assert has_element?(view, "#add-openai-service")
    assert has_element?(view, "#openai-services-empty")
    refute has_element?(view, "#embedding-provider-form")
    view |> element("#add-openai-service") |> render_click()
    assert has_element?(view, "#openai-service-form")
    refute has_element?(view, "#openai-service-form [name='service[credential]']")

    view
    |> form("#openai-service-form", %{
      service: %{
        provider_id: provider.id,
        model_policy: "passthrough",
        models_text: "",
        default_model: ""
      }
    })
    |> render_submit()

    assert [service] = Service.list(:embeddings)
    assert service.enabled
    assert service.model_policy == :passthrough
    assert service.models == []
    assert has_element?(view, "#openai-services-table", "Client-supplied model")
    assert has_element?(view, "#openai-services-table", "Configured")
    assert ProviderApi.get(api.id).native_protocols == []
    assert Provider.get(provider.id).credential == credential
    refute render(view) =~ "sk-private-embedding"
    view |> element("#toggle-service-#{service.id}") |> render_click()
    refute Service.get(service.id).enabled
    view |> element("#edit-service-#{service.id}") |> render_click()

    view
    |> form("#openai-service-form", %{
      service: %{
        model_policy: "allowlist",
        models_text: "text-embedding-3-small",
        default_model: "text-embedding-3-small"
      }
    })
    |> render_submit()

    assert %{enabled: false, models: ["text-embedding-3-small"]} = Service.get(service.id)
  end

  test "disabled APIs remain visible with their configured restriction", %{
    conn: conn,
    credential: credential
  } do
    {:ok, provider} = Provider.create(%{name: "restricted-embedding", credential: credential})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1"
      })

    {:ok, _} =
      Service.create(%{
        provider_id: provider.id,
        kind: :embeddings,
        models: ["allowed-model"],
        enabled: false
      })

    {:ok, _view, html} = live(conn, "/llama/embedding")
    assert html =~ "Disabled"
    assert html =~ "restricted-embedding/allowed-model"
    refute html =~ "Client-supplied model"
  end

  test "retains existing embedding connections as a read-only compatibility inventory", %{
    conn: conn,
    credential: credential
  } do
    {:ok, _} =
      Embedding.create_provider_with_model(%{
        "name" => "legacy-embedding",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "model" => "legacy-model",
        "model_enabled" => "true",
        "default_headers" => "{}",
        "metadata" => "{}"
      })

    {:ok, view, html} = live(conn, "/llama/embedding")
    assert has_element?(view, "#legacy-embedding-models-table")
    assert html =~ "legacy-embedding/legacy-model"
    refute has_element?(view, "button[phx-click='edit_provider']")
    refute has_element?(view, "button[phx-click='delete_provider']")
  end
end
