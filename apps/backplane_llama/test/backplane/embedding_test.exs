defmodule Backplane.EmbeddingTest do
  use Backplane.DataCase, async: false

  alias Backplane.Embedding
  alias Backplane.Settings.Credentials

  setup do
    credential = "embedding-context-cred-#{System.unique_integer([:positive])}"
    {:ok, _credential} = Credentials.store(credential, "sk-embedding-test", "llm")

    {:ok, credential: credential}
  end

  test "creates, lists, and resolves enabled embedding models", %{credential: credential} do
    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-context",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => ~s({"x-provider": "embedding"}),
        "model" => "text-embedding-3-small",
        "display_name" => "Text Embedding 3 Small",
        "model_enabled" => "true",
        "metadata" => ~s({"dimensions": 1536})
      })

    [model] = Embedding.list_enabled_models()

    assert Embedding.model_id(model) == "embedding-context/text-embedding-3-small"
    assert model.provider.name == "embedding-context"

    assert {:ok, provider, "text-embedding-3-small"} =
             Embedding.resolve_model("embedding-context/text-embedding-3-small")

    assert provider.base_url == "https://api.example.com/v1"
  end

  test "does not list disabled embedding providers", %{credential: credential} do
    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-disabled-provider",
        "credential" => credential,
        "enabled" => "false",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-disabled",
        "display_name" => "",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    assert Embedding.list_enabled_models() == []

    assert {:error, :no_provider} =
             Embedding.resolve_model("embedding-disabled-provider/text-embedding-disabled")
  end

  test "updates an embedding provider and model together", %{credential: credential} do
    {:ok, %{model: model}} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-edit",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-3-small",
        "display_name" => "Text Embedding 3 Small",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    assert {:ok, %{provider: provider, model: updated_model}} =
             Embedding.update_provider_with_model(model, %{
               "name" => "embedding-edited",
               "credential" => credential,
               "enabled" => "true",
               "base_url" => "https://api.example.com/v2/",
               "default_headers" => ~s({"x-provider": "edited"}),
               "model" => "text-embedding-3-large",
               "display_name" => "Text Embedding 3 Large",
               "model_enabled" => "true",
               "metadata" => ~s({"dimensions": 3072})
             })

    assert provider.name == "embedding-edited"
    assert provider.base_url == "https://api.example.com/v2"
    assert provider.default_headers == %{"x-provider" => "edited"}
    assert updated_model.model == "text-embedding-3-large"
    assert updated_model.display_name == "Text Embedding 3 Large"
    assert updated_model.metadata == %{"dimensions" => 3072}

    assert {:error, :no_provider} =
             Embedding.resolve_model("embedding-edit/text-embedding-3-small")

    assert {:ok, _provider, "text-embedding-3-large"} =
             Embedding.resolve_model("embedding-edited/text-embedding-3-large")
  end

  test "soft delete disables and excludes embedding providers", %{credential: credential} do
    {:ok, %{provider: provider}} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-delete",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-3-small",
        "display_name" => "",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    assert [_model] = Embedding.list_enabled_models()
    assert {:ok, deleted} = Embedding.soft_delete_provider(provider)
    assert deleted.enabled == false
    assert %DateTime{} = deleted.deleted_at
    assert Embedding.list_enabled_models() == []
  end

  test "builds OpenAI-compatible embedding auth headers", %{credential: credential} do
    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => "embedding-auth",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => ~s({"x-org-id": "org-123"}),
        "model" => "text-embedding-3-small",
        "display_name" => "",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    assert {:ok, provider, _raw_model} =
             Embedding.resolve_model("embedding-auth/text-embedding-3-small")

    assert {:ok, headers} = Embedding.build_auth_headers(provider)
    assert {"authorization", "Bearer sk-embedding-test"} in headers
    assert {"x-org-id", "org-123"} in headers
  end
end
