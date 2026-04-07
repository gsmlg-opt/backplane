defmodule Backplane.LLM.ModelResolverTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.ModelAlias
  alias Backplane.LLM.ModelResolver
  alias Backplane.LLM.Provider

  @anthropic_attrs %{
    name: "anthropic-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    api_key: "sk-ant-test-key",
    models: ["claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"]
  }

  @openai_attrs %{
    name: "openai-provider",
    api_type: :openai,
    api_url: "https://api.openai.com",
    api_key: "sk-openai-test-key",
    models: ["gpt-4o", "gpt-4o-mini"]
  }

  setup do
    start_supervised!(ModelResolver)
    :ok
  end

  # ── resolve/2 - prefixed ──────────────────────────────────────────────────────

  describe "resolve/2 - prefixed" do
    test "resolves provider_name/model to provider and raw model" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      assert {:ok, resolved_provider, raw_model} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-3-5-sonnet-20241022")

      assert resolved_provider.id == provider.id
      assert raw_model == "claude-3-5-sonnet-20241022"
    end

    test "returns :no_provider for unknown provider name" do
      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "nonexistent-provider/claude-3-5-sonnet-20241022")
    end

    test "returns :no_provider for known provider but unknown model" do
      {:ok, _provider} = Provider.create(@anthropic_attrs)

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/unknown-model")
    end

    test "returns :api_type_mismatch when provider api_type differs" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      assert {:error, :api_type_mismatch, mismatch_provider} =
               ModelResolver.resolve(:openai, "anthropic-provider/claude-3-5-sonnet-20241022")

      assert mismatch_provider.id == provider.id
    end

    test "skips disabled providers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)
      {:ok, _} = Provider.update(provider, %{enabled: false})

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-3-5-sonnet-20241022")
    end

    test "skips soft-deleted providers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)
      {:ok, _} = Provider.soft_delete(provider)

      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-3-5-sonnet-20241022")
    end
  end

  # ── resolve/2 - alias ─────────────────────────────────────────────────────────

  describe "resolve/2 - alias" do
    test "resolves alias to provider and raw model" do
      {:ok, provider} = Provider.create(@openai_attrs)

      {:ok, _} =
        ModelAlias.create(%{
          alias: "fast",
          model: "gpt-4o-mini",
          provider_id: provider.id
        })

      assert {:ok, resolved_provider, raw_model} = ModelResolver.resolve(:openai, "fast")
      assert resolved_provider.id == provider.id
      assert raw_model == "gpt-4o-mini"
    end

    test "returns :no_provider for unknown alias" do
      assert {:error, :no_provider} = ModelResolver.resolve(:openai, "nonexistent-alias")
    end

    test "returns :api_type_mismatch when alias provider api_type differs" do
      {:ok, provider} = Provider.create(@openai_attrs)

      {:ok, _} =
        ModelAlias.create(%{
          alias: "openai-fast",
          model: "gpt-4o-mini",
          provider_id: provider.id
        })

      assert {:error, :api_type_mismatch, mismatch_provider} =
               ModelResolver.resolve(:anthropic, "openai-fast")

      assert mismatch_provider.id == provider.id
    end

    test "skips aliases for disabled providers" do
      {:ok, provider} = Provider.create(@openai_attrs)

      {:ok, _} =
        ModelAlias.create(%{
          alias: "disabled-provider-alias",
          model: "gpt-4o",
          provider_id: provider.id
        })

      {:ok, _} = Provider.update(provider, %{enabled: false})

      assert {:error, :no_provider} = ModelResolver.resolve(:openai, "disabled-provider-alias")
    end
  end

  # ── resolve/2 - no fallback ───────────────────────────────────────────────────

  describe "resolve/2 - no fallback" do
    test "unprefixed non-alias returns :no_provider" do
      {:ok, _provider} = Provider.create(@anthropic_attrs)

      # "claude-3-5-sonnet-20241022" is a valid model name but not a registered alias
      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "claude-3-5-sonnet-20241022")
    end
  end

  # ── cache ─────────────────────────────────────────────────────────────────────

  describe "cache" do
    test "invalidates on provider change via PubSub" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      # First resolve — caches the result
      assert {:ok, _p, _m} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-3-5-sonnet-20241022")

      # Update provider to disabled — broadcasts {:llm_providers_changed, %{}} on "llm:providers"
      {:ok, _} = Provider.update(provider, %{enabled: false})

      # Give the GenServer time to receive the PubSub message and clear the cache
      Process.sleep(50)

      # Resolve again — cache should be cleared, result re-queried
      assert {:error, :no_provider} =
               ModelResolver.resolve(:anthropic, "anthropic-provider/claude-3-5-sonnet-20241022")
    end
  end
end
