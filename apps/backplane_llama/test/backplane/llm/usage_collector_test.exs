defmodule Backplane.LLM.UsageCollectorTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{Provider, UsageCollector, UsageLog}
  alias Backplane.Settings.Credentials

  @provider_attrs %{
    name: "collector-test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "collector-test-cred",
    models: ["claude-3-5-sonnet-20241022"]
  }

  setup do
    Credentials.store("collector-test-cred", "sk-ant-test-key", "llm")
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
      handler_id = Backplane.LLM.TelemetryCapture.attach(self(), [:backplane, :llm, :request])
      on_exit(fn -> Backplane.LLM.TelemetryCapture.detach(handler_id) end)

      :telemetry.execute(
        [:backplane, :llm, :request],
        %{latency_ms: 200, system_time: System.system_time()},
        %{
          provider_id: provider.id,
          model: "claude-3-5-sonnet-20241022",
          status: 200,
          input_tokens: 50,
          output_tokens: 25,
          stream: false,
          client_ip: "127.0.0.1",
          error_reason: nil
        }
      )

      assert_receive {:telemetry_capture, [:backplane, :llm, :request], measurements, metadata}
      assert measurements.latency_ms == 200
      assert metadata.provider_id == provider.id
      assert metadata.model == "claude-3-5-sonnet-20241022"

      # Oban is in :inline testing mode, so the job runs immediately.
      # Verify the side-effect: a UsageLog record was persisted.
      log = Repo.one(UsageLog)
      assert log != nil
      assert log.provider_id == provider.id
      assert log.model == "claude-3-5-sonnet-20241022"
      assert log.latency_ms == 200
      assert log.input_tokens == 50
      assert log.output_tokens == 25
      assert log.stream == false
      assert log.client_ip == "127.0.0.1"
    end
  end
end
