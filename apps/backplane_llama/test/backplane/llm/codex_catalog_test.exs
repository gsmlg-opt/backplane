defmodule Backplane.LLM.CodexCatalogTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{
    CodexCatalog,
    CodexCatalogEntry,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    credential = "codex-catalog-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Credentials.store_device_token(
        credential,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "catalog-access-token",
          "refresh_token" => "catalog-refresh-token",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "catalog-account"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "catalog-provider-#{System.unique_integer([:positive])}",
        credential: credential,
        preset_key: "openai-codex"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        native_protocols: [:openai_responses]
      })

    %{provider: provider, api: api}
  end

  test "lists only eligible Codex providers without discovery", %{provider: provider} do
    assert Enum.any?(CodexCatalog.providers(), &(&1.id == provider.id))

    {:ok, disabled} = Provider.update(provider, %{enabled: false})
    refute Enum.any?(CodexCatalog.providers(), &(&1.id == disabled.id))
  end

  test "orders saved descriptors and resolves the raw public slug", %{
    provider: provider,
    api: api
  } do
    later = insert_entry(provider, api, "gpt-zeta", 20)
    earlier = insert_entry(provider, api, "gpt-alpha", 10)
    ModelResolver.clear_cache()

    assert Enum.map(CodexCatalog.list(), & &1.id) == [earlier.id, later.id]

    assert Enum.map(elem(CodexCatalog.response(), 0)["models"], & &1["slug"]) ==
             ["gpt-alpha", "gpt-zeta"]

    assert CodexCatalog.target_for("gpt-alpha") == "#{provider.name}/gpt-alpha"
    assert {:ok, resolved, "gpt-alpha"} = ModelResolver.resolve(:openai, "gpt-alpha")
    assert resolved.id == provider.id
  end

  test "publishes every stored upstream property without synthesis", %{
    provider: provider,
    api: api
  } do
    entry = insert_entry(provider, api, "gpt-raw", 7)

    assert {:ok, effective} = CodexCatalog.effective_entry(entry)
    assert effective.descriptor == entry.metadata["codex_raw"]
    assert effective.descriptor["unknown_field"] == %{"nested" => [1, 2]}
    assert effective.descriptor["priority"] == 7
  end

  test "legacy entries cannot be enabled or routed", %{provider: provider, api: api} do
    insert_entry(provider, api, "gpt-valid", 10)

    legacy =
      Repo.insert!(%CodexCatalogEntry{
        public_model_id: "legacy",
        source_model: "#{provider.name}/gpt-valid",
        enabled: false
      })

    assert {:error, _} = CodexCatalog.toggle(legacy)
    assert CodexCatalog.target_for("legacy") == nil
  end

  test "disabled provider excludes a saved entry", %{provider: provider, api: api} do
    insert_entry(provider, api, "gpt-disabled", 10)
    {:ok, _} = Provider.update(provider, %{enabled: false})
    ModelResolver.clear_cache()

    {response, invalid} = CodexCatalog.response()
    assert response == %{"models" => []}
    assert [{%{public_model_id: "gpt-disabled"}, _reason}] = invalid
    assert CodexCatalog.target_for("gpt-disabled") == nil
  end

  test "a saved slug resolves the active provider after a soft-deleted name is reused", %{
    provider: provider,
    api: api
  } do
    entry = insert_entry(provider, api, "gpt-reused", 10)
    assert {:ok, _} = Provider.soft_delete(provider)

    {:ok, replacement} =
      Provider.create(%{
        name: provider.name,
        credential: provider.credential,
        preset_key: "openai-codex"
      })

    {:ok, replacement_api} =
      ProviderApi.create(%{
        provider_id: replacement.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        native_protocols: [:openai_responses]
      })

    {:ok, replacement_model} =
      ProviderModel.create(%{
        provider_id: replacement.id,
        model: "gpt-reused",
        source: :discovered
      })

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: replacement_model.id,
        provider_api_id: replacement_api.id
      })

    ModelResolver.clear_cache()
    assert {:ok, effective} = CodexCatalog.effective_entry(entry)
    assert effective.provider.id == replacement.id
    assert CodexCatalog.target_for("gpt-reused") == "#{provider.name}/gpt-reused"
    assert {%{"models" => [%{"slug" => "gpt-reused"}]}, []} = CodexCatalog.response()
  end

  test "a saved slug with only a soft-deleted provider stays unavailable", %{
    provider: provider,
    api: api
  } do
    entry = insert_entry(provider, api, "gpt-retired", 10)
    assert {:ok, _} = Provider.soft_delete(provider)
    ModelResolver.clear_cache()

    assert {:error, :invalid_codex_provider} = CodexCatalog.effective_entry(entry)
    assert CodexCatalog.target_for("gpt-retired") == nil
    assert {%{"models" => []}, [{^entry, :invalid_codex_provider}]} = CodexCatalog.response()
  end

  test "an unavailable enabled entry can still be disabled", %{provider: provider, api: api} do
    entry = insert_entry(provider, api, "gpt-unavailable", 10)
    {:ok, _} = Provider.update(provider, %{enabled: false})

    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    refute disabled.enabled
  end

  test "toggle hides and republishes a saved entry", %{provider: provider, api: api} do
    entry = insert_entry(provider, api, "gpt-toggle", 10)
    assert length(elem(CodexCatalog.response(), 0)["models"]) == 1

    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    assert elem(CodexCatalog.response(), 0) == %{"models" => []}

    assert {:ok, enabled} = CodexCatalog.toggle(disabled)
    assert enabled.enabled
    assert length(elem(CodexCatalog.response(), 0)["models"]) == 1
  end

  test "deletes a saved entry", %{provider: provider, api: api} do
    entry = insert_entry(provider, api, "gpt-delete", 10)
    assert {:ok, deleted} = CodexCatalog.delete(entry)
    assert deleted.id == entry.id
    assert CodexCatalog.get(entry.id) == nil
  end

  defp insert_entry(provider, api, slug, priority) do
    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: slug, source: :discovered})

    {:ok, _surface} =
      ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})

    raw = %{
      "slug" => slug,
      "display_name" => "Display #{slug}",
      "priority" => priority,
      "unknown_field" => %{"nested" => [1, 2]}
    }

    Repo.insert!(%CodexCatalogEntry{
      public_model_id: slug,
      source_model: "#{provider.name}/#{slug}",
      display_name: raw["display_name"],
      priority: priority,
      metadata: %{"codex_raw" => raw},
      enabled: true
    })
  end
end
