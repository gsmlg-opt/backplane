defmodule Backplane.LLM.AutoModelResolverTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{
    ModelAlias,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Settings.Credentials

  setup do
    credential = "resolver-auto-#{System.unique_integer([:positive])}"
    Credentials.store(credential, "sk-test", "llm")
    ModelResolver.clear_cache()
    :ok = Backplane.Settings.set("llm.model_aliases.custom", %{})
    :ok = Backplane.Settings.set("llm.auto_models.smart.targets", ["minimax-m2.7"])

    {:ok, provider} =
      Provider.create(%{
        name: "resolver-auto-provider-#{System.unique_integer([:positive])}",
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
        model: "minimax-m2.7",
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    %{provider: provider}
  end

  test "resolves smart through configured model alias settings", %{provider: provider} do
    assert {:ok, resolved_provider, raw_model} = ModelResolver.resolve(:openai, "smart")
    assert resolved_provider.id == provider.id
    assert raw_model == "minimax-m2.7"
  end

  test "resolves custom alias pointing to built-in auto model", %{provider: provider} do
    assert {:ok, _alias} = ModelAlias.put("coding", "smart")

    assert {:ok, resolved_provider, raw_model} = ModelResolver.resolve(:openai, "coding")
    assert resolved_provider.id == provider.id
    assert raw_model == "minimax-m2.7"
  end

  test "resolves custom alias pointing to provider model id", %{provider: provider} do
    assert {:ok, _alias} = ModelAlias.put("mini", "minimax-m2.7")

    assert {:ok, resolved_provider, raw_model} = ModelResolver.resolve(:openai, "mini")
    assert resolved_provider.id == provider.id
    assert raw_model == "minimax-m2.7"
  end
end
