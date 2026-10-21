defmodule Backplane.Memory.Workers.LessonDecayWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Workers.LessonDecayWorker

  @trace %{actor: "operator", request_id: "decay-worker", correlation_id: "decay-worker"}

  test "enqueued worker executes decay only within the canonical space and retry is idempotent" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      partition = canonical_partition("decay-execution")
      foreign_space = canonical_partition("decay-foreign").memory_space_id
      foreign = Map.put(partition, :memory_space_id, foreign_space)
      assert {:ok, own} = save_lesson(partition, "own")
      assert {:ok, other} = save_lesson(foreign, "foreign")
      now = ~U[2026-10-19 03:15:00Z]

      assert {:ok, job} = LessonDecayWorker.enqueue(partition, now)
      assert job.args["memory_space_id"] == partition.memory_space_id
      assert :ok = LessonDecayWorker.perform(job)
      assert :ok = LessonDecayWorker.perform(job)

      assert %{last_decayed_at: decayed_at, decay_rate: 0.05} = repo().get!(Lesson, own.memory_id)
      assert DateTime.compare(decayed_at, now) == :eq

      assert %{last_decayed_at: nil, decay_rate: other_decay} =
               repo().get!(Lesson, other.memory_id)

      assert other_decay == 0.0
      assert repo().get!(Memory, other.memory_id).lifecycle_state == "active"
    end)
  end

  test "full batches enqueue a continuation with the complete partition and fixed clock" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      partition = canonical_partition("decay-continuation")

      for index <- 1..101 do
        assert {:ok, _lesson} = save_lesson(partition, "batch-#{index}")
      end

      now = ~U[2026-10-19 03:15:00Z]
      assert {:ok, job} = LessonDecayWorker.enqueue(partition, now)
      assert :ok = LessonDecayWorker.perform(job)

      assert [continuation] =
               Styx.Testing.all_enqueued(repo(), worker: LessonDecayWorker)
               |> Enum.reject(&(&1.id == job.id))

      assert continuation.args == job.args
      assert :ok = LessonDecayWorker.perform(continuation)

      assert repo().aggregate(from(l in Lesson, where: l.last_decayed_at == ^now), :count) == 101
      assert repo().aggregate(from(l in Lesson, where: l.decay_rate == 0.05), :count) == 101
    end)
  end

  test "one generator job cannot decay or archive same-space sibling host or client identities" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      partition = canonical_partition("decay-shared-space")
      assert {:ok, own} = save_lesson(partition, "shared-own")

      siblings =
        for {key, value} <- [host_id: "sibling-host", client_id: "sibling-client"] do
          assert {:ok, sibling} =
                   save_lesson(Map.put(partition, key, value), "shared-#{key}")

          sibling
        end

      now =
        DateTime.add(
          own.created_at,
          Backplane.Memory.Config.lesson_decay_archive_days() + 1,
          :day
        )

      assert {:ok, job} = LessonDecayWorker.enqueue(partition, now)
      assert :ok = LessonDecayWorker.perform(job)
      assert :ok = LessonDecayWorker.perform(job)

      assert %{status: "archived", decay_rate: 0.05, last_decayed_at: ^now} =
               repo().get!(Lesson, own.memory_id)

      assert repo().get!(Memory, own.memory_id).lifecycle_state == "archived"

      for sibling <- siblings do
        assert %{status: "active", decay_rate: sibling_decay, last_decayed_at: nil} =
                 repo().get!(Lesson, sibling.memory_id)

        assert sibling_decay == 0.0
        assert repo().get!(Memory, sibling.memory_id).lifecycle_state == "active"
      end
    end)
  end

  test "rejects incomplete partitions and malformed job clocks without raising" do
    partition = canonical_partition("decay-invalid")
    now = ~U[2026-10-19 03:15:00Z]

    for key <- [:memory_space_id, :host_id, :client_id, :scope, :namespace] do
      incomplete = Map.delete(partition, key)
      assert {:error, :incomplete_partition} = LessonDecayWorker.enqueue(incomplete, now)

      args = Map.new(incomplete, fn {key, value} -> {to_string(key), value} end)
      args = Map.put(args, "now", DateTime.to_iso8601(now))
      assert {:cancel, :incomplete_partition} = LessonDecayWorker.perform(%Styx.Job{args: args})
    end

    args = Map.new(partition, fn {key, value} -> {to_string(key), value} end)

    for invalid <- [nil, "invalid-date", 123] do
      assert {:cancel, :invalid_arguments} =
               LessonDecayWorker.perform(%Styx.Job{args: Map.put(args, "now", invalid)})
    end

    assert {:cancel, :invalid_arguments} = LessonDecayWorker.perform(%Styx.Job{args: nil})
  end

  defp save_lesson(partition, key) do
    Lessons.save(
      %{rule: "decay #{key}", context: "test", project: "backplane", idempotency_key: key},
      partition,
      @trace
    )
  end
end
