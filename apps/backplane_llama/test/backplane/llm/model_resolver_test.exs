defmodule Backplane.LLM.ModelResolverTest do
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
    Credentials.store("resolver-anthropic-cred", "sk-ant-test-key", "llm")
    Credentials.store("resolver-openai-cred", "sk-openai-test-key", "llm")
    ModelResolver.clear_cache()
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok
  end

  describe "resolve/2 - prefixed" do
    test "resolves provider_name/model to provider and raw model" do
      provider = create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")

      assert {:ok, resolved_provider, raw_model} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-sonnet")

      assert resolved_provider.id == provider.id
      assert raw_model == "claude-sonnet"
    end

    test "returns :no_provider for unknown provider name" do
      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "nonexistent-provider/claude-sonnet")
    end

    test "returns :no_provider for known provider but unknown model" do
      create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/unknown-model")
    end

    test "returns :no_provider when API surface differs" do
      create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")

      assert {:error, :no_provider} =
               ModelResolver.resolve(:openai, "anthropic-provider/claude-sonnet")
    end

    test "skips disabled providers" do
      provider = create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")
      {:ok, _} = Provider.update(provider, %{enabled: false})

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-sonnet")
    end

    test "skips soft-deleted providers" do
      provider = create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")
      {:ok, _} = Provider.soft_delete(provider)

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-sonnet")
    end
  end

  describe "resolve/2 - alias" do
    test "resolves custom alias to provider model target" do
      provider = create_provider_model("openai-provider", :openai, "gpt-4o-mini")
      {:ok, _} = ModelAlias.put("coding", "gpt-4o-mini")

      assert {:ok, resolved_provider, raw_model} = ModelResolver.resolve(:openai, "coding")
      assert resolved_provider.id == provider.id
      assert raw_model == "gpt-4o-mini"
    end

    test "returns :no_provider for unknown alias" do
      assert {:error, :no_provider} = ModelResolver.resolve(:openai, "nonexistent-alias")
    end

    test "returns :no_provider when alias target has no matching API surface" do
      create_provider_model("openai-provider", :openai, "gpt-4o-mini")
      {:ok, _} = ModelAlias.put("coding", "gpt-4o-mini")

      assert {:error, :no_provider} = ModelResolver.resolve(:anthropic, "coding")
    end

    test "skips aliases for disabled providers" do
      provider = create_provider_model("openai-provider", :openai, "gpt-4o-mini")
      {:ok, _} = ModelAlias.put("coding", "gpt-4o-mini")
      {:ok, _} = Provider.update(provider, %{enabled: false})

      assert {:error, :no_provider} = ModelResolver.resolve(:openai, "coding")
    end
  end

  describe "resolve/2 - no fallback" do
    test "unprefixed non-alias returns :no_provider" do
      create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")

      assert {:error, :no_provider} = ModelResolver.resolve(:anthropic, "claude-sonnet")
    end
  end

  describe "cache" do
    test "invalidates on provider change via PubSub" do
      provider = create_provider_model("anthropic-provider", :anthropic, "claude-sonnet")

      assert {:ok, _provider, _model} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-sonnet")

      {:ok, _} = Provider.update(provider, %{enabled: false})
      Process.sleep(50)

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-sonnet")
    end
  end

  defp create_provider_model(name, api_surface, model_id) do
    credential =
      case api_surface do
        :anthropic -> "resolver-anthropic-cred"
        :openai -> "resolver-openai-cred"
      end

    {:ok, provider} =
      Provider.create(%{
        name: name,
        credential: credential
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: api_surface,
        base_url: "https://api.example.com/v1"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    provider
  end
end
