defmodule Backplane.Memory.Workers.ActivityRetentionWorkerTest do
  use Backplane.Memory.DataCase, async: false
  use Styx.Testing, repo: Backplane.Repo

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily}
  alias Backplane.Memory.Workers.ActivityRetentionWorker

  test "empty activity tables do not create purge audit entries or continuation jobs" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{contributions_deleted: 0, daily_deleted: 0, continued: false}} =
               ActivityRetentionWorker.perform(%Styx.Job{args: %{"today" => "2026-08-12"}})

      assert Audit.list(operation: "memory.activity.purge") == []
      refute_enqueued(worker: ActivityRetentionWorker)
    end)
  end

  test "retained activity remains untouched without creating a purge audit entry" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("at-cutoff", ~D[2024-08-12])
      insert_pair!("retained", ~D[2026-08-01])
      contributions = repo().all(ActivityContribution)
      daily = repo().all(ActivityDaily)

      assert {:ok, %{contributions_deleted: 0, daily_deleted: 0, continued: false}} =
               ActivityRetentionWorker.perform(%Styx.Job{args: %{"today" => "2026-08-12"}})

      assert repo().all(ActivityContribution) == contributions
      assert repo().all(ActivityDaily) == daily
      assert Audit.list(operation: "memory.activity.purge") == []
      refute_enqueued(worker: ActivityRetentionWorker)
    end)
  end

  test "expired daily rows are audited when no contributions are deleted" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("daily-only", ~D[2024-08-01], [ActivityDaily])

      assert {:ok, %{contributions_deleted: 0, daily_deleted: 1, continued: false}} =
               ActivityRetentionWorker.perform(%Styx.Job{args: %{"today" => "2026-08-12"}})

      assert repo().aggregate(ActivityDaily, :count) == 0
      assert [%{metadata: metadata}] = Audit.list(operation: "memory.activity.purge")
      assert metadata["daily_deleted"] == 1
      assert metadata["contributions_deleted"] == 0
      refute_enqueued(worker: ActivityRetentionWorker)
    end)
  end

  test "expired contributions are audited when no daily rows are deleted" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("contribution-only", ~D[2024-08-01], [ActivityContribution])

      assert {:ok, %{contributions_deleted: 1, daily_deleted: 0, continued: false}} =
               ActivityRetentionWorker.perform(%Styx.Job{args: %{"today" => "2026-08-12"}})

      assert repo().aggregate(ActivityContribution, :count) == 0
      assert [%{metadata: metadata}] = Audit.list(operation: "memory.activity.purge")
      assert metadata["contributions_deleted"] == 1
      assert metadata["daily_deleted"] == 0
      refute_enqueued(worker: ActivityRetentionWorker)
    end)
  end

  test "the empty batch after a full purge adds no audit or continuation job" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("one-full-batch", ~D[2024-08-01])
      job = %Styx.Job{args: %{"today" => "2026-08-12", "batch_size" => 1}}

      assert {:ok, %{contributions_deleted: 1, daily_deleted: 1, continued: true}} =
               ActivityRetentionWorker.perform(job)

      assert [audit] = Audit.list(operation: "memory.activity.purge")
      assert [continuation] = Styx.Testing.all_enqueued(repo(), worker: ActivityRetentionWorker)

      assert {:ok, %{contributions_deleted: 0, daily_deleted: 0, continued: false}} =
               ActivityRetentionWorker.perform(job)

      assert Audit.list(operation: "memory.activity.purge") == [audit]
      assert Styx.Testing.all_enqueued(repo(), worker: ActivityRetentionWorker) == [continuation]
    end)
  end

  test "purges only expired aggregate rows in bounded batches and audits the result" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      insert_pair!("expired-a", ~D[2024-08-01])
      insert_pair!("expired-b", ~D[2024-08-02])
      insert_pair!("retained", ~D[2026-08-01])

      assert {:ok, %{contributions_deleted: 1, daily_deleted: 1, continued: true}} =
               ActivityRetentionWorker.perform(%Styx.Job{
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
      Application.fetch_env!(:backplane, Styx)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _opts} -> plugin == Styx.Cron end)

    assert {"45 3 * * *", ActivityRetentionWorker} in Keyword.fetch!(opts, :crontab)
  end

  defp insert_pair!(subject_id, date, tables \\ [ActivityDaily, ActivityContribution]) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    memory_space_id = Backplane.Memory.IngestFixtures.ensure_memory_space!("activity-retention")

    dimensions = %{
      memory_space_id: memory_space_id,
      date: date,
      project: subject_id,
      agent_id: "agent",
      host_id: "host",
      client_id: "client",
      source_client_id: "client",
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

    if ActivityDaily in tables do
      repo().insert_all(ActivityDaily, [Map.merge(dimensions, counters)])
    end

    if ActivityContribution in tables do
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
end
