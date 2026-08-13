defmodule Backplane.Memory.Workers.ActivityRetentionWorkerTest do
  use Backplane.Memory.DataCase, async: false
  use Oban.Testing, repo: Backplane.Repo

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily}
  alias Backplane.Memory.Workers.ActivityRetentionWorker

  test "purges only expired aggregate rows in bounded batches and audits the result" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("expired-a", ~D[2024-08-01])
      insert_pair!("expired-b", ~D[2024-08-02])
      insert_pair!("retained", ~D[2026-08-01])

      assert {:ok, %{contributions_deleted: 1, daily_deleted: 1, continued: true}} =
               ActivityRetentionWorker.perform(%Oban.Job{
                 args: %{"today" => "2026-08-12", "batch_size" => 1}
               })

      assert_enqueued(
        worker: ActivityRetentionWorker,
        args: %{"today" => "2026-08-12", "batch_size" => 1}
      )

      subjects = ["expired-a", "expired-b", "retained"]

      assert repo().aggregate(
               from(contribution in ActivityContribution,
                 where: contribution.subject_id in ^subjects
               ),
               :count
             ) == 2

      assert repo().aggregate(
               from(daily in ActivityDaily, where: daily.project in ^subjects),
               :count
             ) == 2

      assert [%{metadata: metadata}] =
               Audit.list(operation: "memory.activity.purge", limit: 1)

      assert metadata["contributions_deleted"] == 1
      assert metadata["daily_deleted"] == 1
      assert metadata["cutoff"] == "2024-08-12"
      assert metadata["bounded"] == true
    end)
  end

  test "nightly cron registers the bounded activity retention purge" do
    {_plugin, opts} =
      Application.fetch_env!(:backplane, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _opts} -> plugin == Oban.Plugins.Cron end)

    assert {"45 3 * * *", ActivityRetentionWorker} in Keyword.fetch!(opts, :crontab)
  end

  defp insert_pair!(subject_id, date) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    dimensions = %{
      date: date,
      project: subject_id,
      agent_id: "agent",
      host_id: "host",
      client_id: "client",
      scope: "scope",
      namespace: "private",
      event_type: "agent.prompt.submitted"
    }

    counters = %{
      event_count: 1,
      session_count: 1,
      memory_count: 0,
      lesson_count: 0,
      crystal_count: 0,
      recall_count: 0,
      action_count: 0,
      error_count: 0,
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(ActivityDaily, [Map.merge(dimensions, counters)])

    repo().insert_all(ActivityContribution, [
      dimensions
      |> Map.merge(counters)
      |> Map.merge(%{
        subject_id: subject_id,
        processing_version: "activity-v1",
        input_revision: "revision"
      })
    ])
  end
end
