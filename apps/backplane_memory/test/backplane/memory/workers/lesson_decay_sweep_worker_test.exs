defmodule Backplane.Memory.Workers.LessonDecaySweepWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Workers.{LessonDecaySweepWorker, LessonDecayWorker}

  @trace %{actor: "operator", request_id: "decay-sweep", correlation_id: "decay-sweep"}

  test "schedules one exact-partition job per durable lesson partition" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      for suffix <- ["a", "b"] do
        partition =
          canonical_partition("host-#{suffix}",
            client_id: "client-#{suffix}",
            scope: "project:#{suffix}",
            namespace: "default"
          )

        assert {:ok, _lesson} =
                 Lessons.save(
                   %{
                     rule: "decay #{suffix}",
                     context: "test",
                     project: "backplane",
                     idempotency_key: "decay-#{suffix}"
                   },
                   partition,
                   @trace
                 )
      end

      now = ~U[2026-08-12 03:15:00Z]

      assert :ok =
               LessonDecaySweepWorker.perform(%Styx.Job{
                 args: %{"now" => DateTime.to_iso8601(now)}
               })

      assert jobs = Styx.Testing.all_enqueued(repo(), worker: LessonDecayWorker)
      assert length(jobs) == 2
      assert Enum.map(jobs, & &1.args["host_id"]) |> Enum.sort() == ["host-a", "host-b"]
      assert Enum.all?(jobs, &match?({:ok, _}, Ecto.UUID.cast(&1.args["memory_space_id"])))
      assert Enum.all?(jobs, &(&1.args["now"] == "2026-08-12T03:15:00Z"))
    end)
  end

  test "spaces with identical provenance remain separate scheduled partitions" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      first = canonical_partition("decay-space-a")
      second_space = canonical_partition("decay-space-b").memory_space_id
      second = Map.put(first, :memory_space_id, second_space)

      for partition <- [first, second] do
        assert {:ok, _lesson} = save_lesson(partition, partition.memory_space_id)
      end

      assert :ok = LessonDecaySweepWorker.perform(%Styx.Job{args: %{}})
      jobs = Styx.Testing.all_enqueued(repo(), worker: LessonDecayWorker)
      assert length(jobs) == 2

      assert Enum.sort(Enum.map(jobs, & &1.args["memory_space_id"])) ==
               Enum.sort([first.memory_space_id, second.memory_space_id])
    end)
  end

  test "five-field continuation pages preserve space and enumerate each partition once" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      partition = canonical_partition("decay-pages")

      for index <- 1..101 do
        host = "page-" <> String.pad_leading(Integer.to_string(index), 3, "0")
        assert {:ok, _lesson} = save_lesson(Map.put(partition, :host_id, host), host)
      end

      assert :ok =
               LessonDecaySweepWorker.perform(%Styx.Job{
                 args: %{"now" => "2026-10-19T03:15:00Z"}
               })

      assert length(Styx.Testing.all_enqueued(repo(), worker: LessonDecayWorker)) == 100
      assert [continuation] = Styx.Testing.all_enqueued(repo(), worker: LessonDecaySweepWorker)

      assert continuation.args["cursor"] == [
               partition.memory_space_id,
               "page-100",
               partition.client_id,
               partition.scope,
               partition.namespace
             ]

      assert :ok = LessonDecaySweepWorker.perform(continuation)
      jobs = Styx.Testing.all_enqueued(repo(), worker: LessonDecayWorker)
      assert length(jobs) == 101
      assert length(Enum.uniq_by(jobs, & &1.args["host_id"])) == 101
      assert Enum.all?(jobs, &(&1.args["memory_space_id"] == partition.memory_space_id))
    end)
  end

  test "rejects malformed and stale continuation cursors" do
    assert {:cancel, :invalid_arguments} =
             LessonDecaySweepWorker.perform(%Styx.Job{args: nil})

    assert {:cancel, :invalid_arguments} =
             LessonDecaySweepWorker.perform(%Styx.Job{args: %{"cursor" => ["host"]}})

    assert {:cancel, :invalid_arguments} =
             LessonDecaySweepWorker.perform(%Styx.Job{args: %{"cursor" => ["", "c", "s", "n"]}})

    for cursor <- [
          ["host", "client", "scope", "namespace"],
          ["invalid-space", "host", "client", "scope", "namespace"],
          [Ecto.UUID.generate(), "", "client", "scope", "namespace"]
        ] do
      assert {:cancel, :invalid_arguments} =
               LessonDecaySweepWorker.perform(%Styx.Job{args: %{"cursor" => cursor}})
    end
  end

  test "nightly cron registers the bounded lesson sweep" do
    {_plugin, opts} =
      Application.fetch_env!(:backplane, Styx)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _opts} -> plugin == Styx.Cron end)

    assert {"15 3 * * *", LessonDecaySweepWorker} in Keyword.fetch!(opts, :crontab)
  end

  defp save_lesson(partition, key) do
    Lessons.save(
      %{rule: "decay #{key}", context: "test", project: "backplane", idempotency_key: key},
      partition,
      @trace
    )
  end
end
