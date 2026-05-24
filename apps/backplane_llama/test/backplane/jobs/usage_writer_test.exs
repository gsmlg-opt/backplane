defmodule Backplane.Jobs.UsageWriterTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.UsageWriter
  alias Backplane.LLM.{Provider, UsageLog}
  alias Backplane.Settings.Credentials

  @provider_attrs %{
    name: "writer-test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "writer-test-cred",
    models: ["claude-3-5-sonnet-20241022"]
  }

  setup do
    Credentials.store("writer-test-cred", "sk-ant-test-key", "llm")
    {:ok, provider} = Provider.create(@provider_attrs)
    {:ok, provider: provider}
  end

  describe "perform/1" do
    test "inserts a usage log record from job args", %{provider: provider} do
      args = %{
        "provider_id" => provider.id,
        "model" => "claude-3-5-sonnet-20241022",
        "status" => 200,
        "latency_ms" => 350,
        "input_tokens" => 100,
        "output_tokens" => 50,
        "stream" => false
      }

      job = %Oban.Job{args: args}
      assert :ok = UsageWriter.perform(job)

      log = Repo.one(UsageLog)
      assert log.provider_id == provider.id
      assert log.model == "claude-3-5-sonnet-20241022"
      assert log.status == 200
      assert log.latency_ms == 350
      assert log.input_tokens == 100
      assert log.output_tokens == 50
    end

    test "returns error for missing required fields" do
      args = %{"model" => "claude-3-5-sonnet-20241022"}
      job = %Oban.Job{args: args}
      assert {:error, %Ecto.Changeset{}} = UsageWriter.perform(job)
    end

    test "handles soft-deleted provider gracefully (FK still valid)", %{provider: provider} do
      # Soft-delete the provider — the FK row still exists, so usage logs can be inserted
      {:ok, _} = Provider.soft_delete(provider)

      args = %{
        "provider_id" => provider.id,
        "model" => "claude-3-5-sonnet-20241022"
      }

      job = %Oban.Job{args: args}
      assert :ok = UsageWriter.perform(job)

      log = Repo.one(UsageLog)
      assert log.provider_id == provider.id
    end
  end
end
