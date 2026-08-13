defmodule Backplane.Memory.Workers.LessonDecaySweepWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Workers.{LessonDecaySweepWorker, LessonDecayWorker}

  @trace %{actor: "operator", request_id: "decay-sweep", correlation_id: "decay-sweep"}

  test "schedules one exact-partition job per durable lesson partition" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      for suffix <- ["a", "b"] do
        assert {:ok, _lesson} =
                 Lessons.save(
                   %{
                     rule: "decay #{suffix}",
                     context: "test",
                     project: "backplane",
                     idempotency_key: "decay-#{suffix}"
                   },
                   %{
                     host_id: "host-#{suffix}",
                     client_id: "client-#{suffix}",
                     scope: "project:#{suffix}",
                     namespace: "default"
                   },
                   @trace
                 )
      end

      now = ~U[2026-08-12 03:15:00Z]

      assert :ok =
               LessonDecaySweepWorker.perform(%Oban.Job{
                 args: %{"now" => DateTime.to_iso8601(now)}
               })

      assert jobs = Oban.Testing.all_enqueued(repo(), worker: LessonDecayWorker)
      assert length(jobs) == 2
      assert Enum.map(jobs, & &1.args["host_id"]) |> Enum.sort() == ["host-a", "host-b"]
      assert Enum.all?(jobs, &(&1.args["now"] == "2026-08-12T03:15:00Z"))
    end)
  end

  test "rejects malformed and stale continuation cursors" do
    assert {:cancel, :invalid_arguments} =
             LessonDecaySweepWorker.perform(%Oban.Job{args: %{"cursor" => ["host"]}})

    assert {:cancel, :invalid_arguments} =
             LessonDecaySweepWorker.perform(%Oban.Job{args: %{"cursor" => ["", "c", "s", "n"]}})
  end

  test "nightly cron registers the bounded lesson sweep" do
    {_plugin, opts} =
      Application.fetch_env!(:backplane, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _opts} -> plugin == Oban.Plugins.Cron end)

    assert {"15 3 * * *", LessonDecaySweepWorker} in Keyword.fetch!(opts, :crontab)
  end
end
