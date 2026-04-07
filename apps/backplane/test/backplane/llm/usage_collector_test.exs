defmodule Backplane.LLM.UsageCollectorTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{Provider, UsageCollector, UsageLog}

  @provider_attrs %{
    name: "collector-test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    api_key: "sk-ant-test-key",
    models: ["claude-3-5-sonnet-20241022"]
  }

  setup do
    {:ok, provider} = Provider.create(@provider_attrs)

    # Attach the handler and detach on exit
    UsageCollector.attach()
    on_exit(fn -> UsageCollector.detach() end)

    {:ok, provider: provider}
  end

  describe "handle_event/4" do
    test "enqueues a UsageWriter job (executed inline) which inserts a UsageLog", %{
      provider: provider
    } do
      :telemetry.execute(
        [:backplane, :llm, :request],
        %{latency_ms: 200},
        %{
          provider_id: provider.id,
          model: "claude-3-5-sonnet-20241022",
          status: 200,
          input_tokens: 50,
          output_tokens: 25,
          stream: false
        }
      )

      # Oban is in :inline testing mode, so the job runs immediately.
      # Verify the side-effect: a UsageLog record was persisted.
      log = Repo.one(UsageLog)
      assert log != nil
      assert log.provider_id == provider.id
      assert log.model == "claude-3-5-sonnet-20241022"
      assert log.latency_ms == 200
    end
  end
end
