defmodule Backplane.LLM.UsageQueryTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.{Provider, UsageLog, UsageQuery}

  @provider_attrs %{
    name: "query-test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    api_key: "sk-ant-test-key",
    models: ["claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"]
  }

  setup do
    {:ok, provider} = Provider.create(@provider_attrs)
    {:ok, provider: provider}
  end

  defp insert_log(provider_id, attrs \\ %{}) do
    defaults = %{
      provider_id: provider_id,
      model: "claude-3-5-sonnet-20241022",
      status: 200,
      latency_ms: 100,
      input_tokens: 50,
      output_tokens: 25
    }

    Repo.insert!(struct(UsageLog, Map.merge(defaults, attrs)))
  end

  describe "aggregate/1" do
    test "aggregates usage by provider", %{provider: provider} do
      {:ok, other} =
        Provider.create(%{
          name: "other-provider",
          api_type: :openai,
          api_url: "https://api.openai.com",
          api_key: "sk-other-key",
          models: ["gpt-4o"]
        })

      insert_log(provider.id, %{input_tokens: 100, output_tokens: 50})
      insert_log(provider.id, %{input_tokens: 200, output_tokens: 100})
      insert_log(other.id, %{input_tokens: 999, output_tokens: 999})

      result = UsageQuery.aggregate(%{provider_id: provider.id})

      assert result.total_requests == 2
      assert result.total_input_tokens == 300
      assert result.total_output_tokens == 150
    end

    test "aggregates by model", %{provider: provider} do
      insert_log(provider.id, %{model: "claude-3-5-sonnet-20241022", input_tokens: 100})
      insert_log(provider.id, %{model: "claude-3-5-sonnet-20241022", input_tokens: 200})
      insert_log(provider.id, %{model: "claude-3-haiku-20240307", input_tokens: 50})

      result = UsageQuery.aggregate(%{provider_id: provider.id})

      assert result.total_requests == 3

      sonnet = Enum.find(result.by_model, &(&1.model == "claude-3-5-sonnet-20241022"))
      haiku = Enum.find(result.by_model, &(&1.model == "claude-3-haiku-20240307"))

      assert sonnet.requests == 2
      assert sonnet.input_tokens == 300

      assert haiku.requests == 1
      assert haiku.input_tokens == 50
    end

    test "returns by_status breakdown", %{provider: provider} do
      insert_log(provider.id, %{status: 200})
      insert_log(provider.id, %{status: 200})
      insert_log(provider.id, %{status: 429})
      insert_log(provider.id, %{status: 500})

      result = UsageQuery.aggregate(%{provider_id: provider.id})

      assert result.by_status["200"] == 2
      assert result.by_status["429"] == 1
      assert result.by_status["500"] == 1
    end

    test "computes avg_latency_ms", %{provider: provider} do
      insert_log(provider.id, %{latency_ms: 100})
      insert_log(provider.id, %{latency_ms: 200})
      insert_log(provider.id, %{latency_ms: 300})

      result = UsageQuery.aggregate(%{provider_id: provider.id})

      assert result.avg_latency_ms == 200
    end

    test "returns zero values when no logs match", %{provider: _provider} do
      result = UsageQuery.aggregate(%{provider_id: "00000000-0000-0000-0000-000000000000"})

      assert result.total_requests == 0
      assert result.total_input_tokens == 0
      assert result.total_output_tokens == 0
      assert result.avg_latency_ms == 0
      assert result.by_model == []
      assert result.by_status == %{}
    end
  end
end
