defmodule Backplane.LLM.RouteLoaderTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{Provider, RouteLoader}
  alias Backplane.Settings.Credentials
  alias Relayixir.Config.UpstreamConfig

  @provider_attrs %{
    name: "anthropic-prod",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "route-loader-cred",
    models: ["claude-3-5-sonnet-20241022"]
  }

  setup do
    Credentials.store("route-loader-cred", "sk-ant-test-key", "llm")
    # UpstreamConfig and RouteLoader are started by the application supervision tree.
    # Clear upstream config and resolver cache for test isolation.
    UpstreamConfig.put_upstreams(%{})
    Backplane.LLM.ModelResolver.clear_cache()
    :ok
  end

  describe "boot" do
    test "registers upstream for each active provider after receiving load message" do
      {:ok, provider} = Provider.create(@provider_attrs)

      # Trigger a reload by broadcasting the change event
      Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
      Process.sleep(100)

      upstream_name = RouteLoader.upstream_name(provider.id)
      config = UpstreamConfig.get_upstream(upstream_name)

      assert config != nil
      assert config.host == "api.anthropic.com"
      assert config.scheme == :https
      assert config.port == 443
    end
  end

  describe "provider create" do
    test "registers new upstream after provider is created" do
      {:ok, provider} = Provider.create(@provider_attrs)

      # Give PubSub time to deliver the message
      Process.sleep(100)

      upstream_name = RouteLoader.upstream_name(provider.id)
      config = UpstreamConfig.get_upstream(upstream_name)

      assert config != nil
      assert config.host == "api.anthropic.com"
      assert config.scheme == :https
      assert config.port == 443
      assert config.request_timeout == 300_000
      assert config.first_byte_timeout == 120_000
      assert config.connect_timeout == 10_000
    end
  end

  describe "provider update" do
    test "updates upstream config when provider api_url changes" do
      {:ok, provider} = Provider.create(@provider_attrs)
      Process.sleep(100)

      {:ok, updated} =
        Provider.update(provider, %{
          api_url: "https://api.openai.com",
          models: ["claude-3-5-sonnet-20241022"]
        })

      Process.sleep(100)

      upstream_name = RouteLoader.upstream_name(updated.id)
      config = UpstreamConfig.get_upstream(upstream_name)

      assert config != nil
      assert config.host == "api.openai.com"
    end
  end

  describe "provider delete" do
    test "removes upstream config when provider is soft-deleted" do
      {:ok, provider} = Provider.create(@provider_attrs)
      Process.sleep(100)

      upstream_name = RouteLoader.upstream_name(provider.id)
      assert UpstreamConfig.get_upstream(upstream_name) != nil

      {:ok, _} = Provider.soft_delete(provider)
      Process.sleep(100)

      assert UpstreamConfig.get_upstream(upstream_name) == nil
    end
  end

  describe "upstream_name/1" do
    test "returns prefixed upstream name" do
      assert RouteLoader.upstream_name("some-uuid") == "llm_provider_some-uuid"
    end
  end

  describe "non-LLM upstream preservation" do
    test "does not remove non-LLM upstreams when reloading" do
      # Manually insert a non-LLM upstream
      UpstreamConfig.put_upstreams(%{"other-upstream" => %{host: "example.com", port: 80}})

      {:ok, _provider} = Provider.create(@provider_attrs)
      Process.sleep(100)

      # Non-LLM upstream should still be present
      assert UpstreamConfig.get_upstream("other-upstream") != nil
    end
  end
end
