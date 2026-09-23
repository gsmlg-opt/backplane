defmodule Backplane.LLM.Google.CatalogTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{ModelAlias, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.Google.Catalog
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("google-catalog-key", "secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "google-catalog",
        preset_key: "google-gemini-developer",
        credential: "google-catalog-key"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :google,
        base_url: "https://generativelanguage.example.test/v1beta"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gemini-2.5-pro",
        source: :manual,
        metadata: %{
          "name" => "models/gemini-2.5-pro",
          "displayName" => "Gemini 2.5 Pro",
          "supportedGenerationMethods" => ["generateContent", "countTokens"]
        }
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        metadata: model.metadata
      })

    :ok = ModelAlias.add_provider(provider.name)
    {:ok, _} = ModelAlias.put("pro", "google-catalog/gemini-2.5-pro")
    {:ok, _} = ModelAlias.put("bad:alias", "google-catalog/gemini-2.5-pro")
    {:ok, _} = ModelAlias.put("unsafe", "google-catalog/../secret")

    :ok
  end

  test "lists only URL-safe resolvable aliases and keeps manual provenance explicit" do
    assert {:ok, %{"models" => models}} = Catalog.list(%{"pageSize" => "10"})

    names = Enum.map(models, & &1["name"])
    assert "models/gemini-2.5-pro" in names
    assert "models/pro" in names
    refute "models/bad:alias" in names
    refute "models/unsafe" in names

    descriptor = Enum.find(models, &(&1["name"] == "models/pro"))
    assert descriptor["displayName"] == "Gemini 2.5 Pro"
    assert descriptor["backplaneProvenance"]["source"] == "manual"
    assert descriptor["backplaneProvenance"]["upstreamName"] == "models/gemini-2.5-pro"
  end

  test "supports Google-shaped catalog pagination and get" do
    assert {:ok, %{"models" => [_], "nextPageToken" => token}} =
             Catalog.list(%{"pageSize" => "1"})

    assert {:ok, %{"models" => [_]}} =
             Catalog.list(%{"pageSize" => "1", "pageToken" => token})

    assert {:ok, %{"name" => "models/pro"}} = Catalog.get("pro")
  end
end
