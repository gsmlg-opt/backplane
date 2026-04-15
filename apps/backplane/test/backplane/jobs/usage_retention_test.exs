defmodule Backplane.Jobs.UsageRetentionTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.UsageRetention
  alias Backplane.LLM.{Provider, UsageLog}
  alias Backplane.Settings.Credentials

  @provider_attrs %{
    name: "retention-test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "retention-test-cred",
    models: ["claude-3-5-sonnet-20241022"]
  }

  setup do
    Credentials.store("retention-test-cred", "sk-ant-test-key", "llm")
    {:ok, provider} = Provider.create(@provider_attrs)
    {:ok, provider: provider}
  end

  defp insert_log(provider_id, inserted_at) do
    Repo.insert!(%UsageLog{
      provider_id: provider_id,
      model: "claude-3-5-sonnet-20241022",
      inserted_at: inserted_at
    })
  end

  describe "perform/1" do
    test "deletes logs older than retention period", %{provider: provider} do
      old_ts = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      insert_log(provider.id, old_ts)

      assert Repo.aggregate(UsageLog, :count) == 1

      job = %Oban.Job{}
      assert :ok = UsageRetention.perform(job)

      assert Repo.aggregate(UsageLog, :count) == 0
    end

    test "preserves logs within the retention period", %{provider: provider} do
      old_ts = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      recent_ts = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

      insert_log(provider.id, old_ts)
      insert_log(provider.id, recent_ts)

      assert Repo.aggregate(UsageLog, :count) == 2

      job = %Oban.Job{}
      assert :ok = UsageRetention.perform(job)

      assert Repo.aggregate(UsageLog, :count) == 1
      [remaining] = Repo.all(UsageLog)
      # The remaining log should have inserted_at close to recent_ts
      assert DateTime.diff(remaining.inserted_at, recent_ts, :second) |> abs() < 5
    end
  end
end
