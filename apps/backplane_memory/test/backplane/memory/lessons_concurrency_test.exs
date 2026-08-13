defmodule Backplane.Memory.LessonsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.{Audit, Lessons, Memories}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.ProjectedSession
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 30_000

  test "concurrent identical saves converge on one complete effect" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)

    content = "Concurrent lesson same-#{suffix}"
    results = concurrent_save(12, attrs(content, "same-#{suffix}"), partition)

    assert Enum.all?(results, &match?({:ok, {:ok, %Lesson{}}}, &1))
    assert [memory_id] = results |> memory_ids() |> Enum.uniq()
    assert scoped_lesson_count(partition) == 1

    assert unboxed(fn ->
             repo().aggregate(from(e in Evidence, where: e.memory_id == ^memory_id), :count)
           end) == 1

    assert unboxed(fn -> length(Audit.list(partition, operation: "lesson.save")) end) == 1
  end

  test "concurrent equivalent saves with independent request keys preserve every effect" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)

    content = "Concurrent lesson independent-#{suffix}"

    results =
      concurrent_save(
        12,
        fn ordinal -> attrs(content, "independent-#{suffix}-#{ordinal}") end,
        partition
      )

    assert Enum.all?(results, &match?({:ok, {:ok, %Lesson{}}}, &1))
    assert [memory_id] = results |> memory_ids() |> Enum.uniq()
    assert scoped_lesson_count(partition) == 1

    assert unboxed(fn ->
             repo().aggregate(from(e in Evidence, where: e.memory_id == ^memory_id), :count)
           end) == 12

    assert unboxed(fn ->
             repo().aggregate(
               from(r in RememberRequest, where: r.memory_id == ^memory_id),
               :count
             )
           end) == 12

    assert unboxed(fn -> length(Audit.list(partition, operation: "lesson.save")) end) == 12
  end

  test "concurrent saves cannot bypass an archived lesson's governed state" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)

    content = "Concurrent lesson reactivate-#{suffix}"

    assert {:ok, lesson} =
             unboxed(fn ->
               Lessons.save(attrs(content, "seed-#{suffix}"), partition, trace())
             end)

    unboxed(fn ->
      memory = repo().get!(Memory, lesson.memory_id)
      repo().update!(Memory.lifecycle_changeset(memory, %{lifecycle_state: "archived"}))
      repo().update!(Lesson.changeset(lesson, %{status: "archived"}))
    end)

    results =
      concurrent_save(
        12,
        fn ordinal -> attrs(content, "reactivate-#{suffix}-#{ordinal}") end,
        partition
      )

    assert Enum.all?(results, &match?({:ok, {:error, :governed_state_conflict}}, &1))
    assert unboxed(fn -> repo().get!(Memory, lesson.memory_id).lifecycle_state end) == "archived"
    assert unboxed(fn -> repo().get!(Lesson, lesson.memory_id).status end) == "archived"
    assert scoped_lesson_count(partition) == 1
  end

  test "concurrent strengthening with one stable application key has one effect" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)

    assert {:ok, lesson} =
             unboxed(fn ->
               Lessons.save(attrs("Strengthen #{suffix}", "seed-#{suffix}"), partition, trace())
             end)

    source_session_id = "apply-session-#{suffix}"
    now = DateTime.utc_now()

    unboxed(fn ->
      repo().insert!(%ProjectedSession{
        subject_id: "session:#{partition.host_id}:#{source_session_id}",
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        session_id: source_session_id,
        status: "completed",
        last_event_at: now,
        source_sequence_max: 1,
        gap_count: 0,
        processing_version: "test-v1",
        input_revision: "test-revision"
      })
    end)

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          unboxed(fn ->
            Lessons.strengthen(
              lesson.memory_id,
              "verified_application",
              "apply-#{suffix}",
              %{"source_session_id" => source_session_id},
              partition,
              trace()
            )
          end)
        end,
        max_concurrency: 12,
        timeout: @timeout
      )
      |> Enum.to_list()

    assert Enum.all?(
             results,
             &match?({:ok, {:ok, %{lesson: %Lesson{reinforcement_count: 1}}}}, &1)
           )

    assert unboxed(fn -> repo().get!(Memory, lesson.memory_id).application_count end) == 1
  end

  test "direct apply and verified lesson strengthening share one lock order and one effect" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)
    application_id = "cross-path-#{suffix}"

    assert {:ok, lesson} =
             unboxed(fn ->
               Lessons.save(
                 attrs("Cross path #{suffix}", "seed-cross-#{suffix}"),
                 partition,
                 trace()
               )
             end)

    source_session_id = "cross-path-session-#{suffix}"
    insert_projected_session(source_session_id, partition)
    parent = self()

    tasks = [
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          Memories.record_application(lesson.memory_id, application_id, "executor", partition)
        end)
      end),
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          Lessons.strengthen(
            lesson.memory_id,
            "verified_application",
            application_id,
            %{"source_session_id" => source_session_id},
            partition,
            trace()
          )
        end)
      end)
    ]

    task_pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, @timeout
        pid
      end

    Enum.each(task_pids, &send(&1, :go))
    [direct_result, strengthen_result] = Task.await_many(tasks, @timeout)

    assert {:ok, %{application_count: 1, applied: direct_applied}} = direct_result
    assert {:ok, %{lesson: strengthened, applied: strengthen_applied}} = strengthen_result
    assert Enum.count([direct_applied, strengthen_applied], & &1) == 1
    assert strengthened.reinforcement_count == if(strengthen_applied, do: 1, else: 0)

    unboxed(fn ->
      assert repo().get!(Memory, lesson.memory_id).application_count == 1

      assert repo().get!(Lesson, lesson.memory_id).reinforcement_count ==
               strengthened.reinforcement_count

      assert Enum.count(
               Audit.list_for_target(lesson.memory_id),
               &(&1.operation == "memory.apply")
             ) == 1
    end)
  end

  test "concurrent identical transitions serialize to one audited lifecycle effect" do
    suffix = unique()
    partition = partition(suffix)
    cleanup_on_exit(partition)

    assert {:ok, lesson} =
             unboxed(fn ->
               Lessons.save(
                 attrs("Archive #{suffix}", "seed-archive-#{suffix}"),
                 partition,
                 trace()
               )
             end)

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          unboxed(fn ->
            Lessons.transition(
              lesson.memory_id,
              "archived",
              "retired",
              "archive-#{suffix}",
              partition,
              trace()
            )
          end)
        end,
        max_concurrency: 12,
        timeout: @timeout
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %Lesson{status: "archived"}}}, &1))
    assert unboxed(fn -> length(Audit.list(partition, operation: "lesson.transition")) end) == 1
  end

  defp concurrent_save(count, attrs, partition) do
    1..count
    |> Task.async_stream(
      fn ordinal ->
        attrs = if is_function(attrs, 1), do: attrs.(ordinal), else: attrs
        unboxed(fn -> Lessons.save(attrs, partition, trace()) end)
      end,
      max_concurrency: count,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp memory_ids(results),
    do: Enum.map(results, fn {:ok, {:ok, lesson}} -> lesson.memory_id end)

  defp attrs(content, key) do
    %{
      rule: content,
      context: "concurrency",
      project: "backplane",
      session_id: "session",
      idempotency_key: key
    }
  end

  defp scoped_lesson_count(partition) do
    unboxed(fn ->
      repo().aggregate(
        from(l in Lesson,
          join: m in Memory,
          on: m.id == l.memory_id,
          where: m.host_id == ^partition.host_id and m.client_id == ^partition.client_id
        ),
        :count
      )
    end)
  end

  defp trace do
    %{actor: "authenticated-agent", request_id: Ecto.UUID.generate(), correlation_id: "corr"}
  end

  defp insert_projected_session(session_id, partition) do
    now = DateTime.utc_now()

    unboxed(fn ->
      repo().insert!(%ProjectedSession{
        subject_id: "session:#{partition.host_id}:#{session_id}",
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        session_id: session_id,
        status: "completed",
        last_event_at: now,
        source_sequence_max: 1,
        gap_count: 0,
        processing_version: "test-v1",
        input_revision: "test-revision"
      })
    end)
  end

  defp partition(suffix) do
    %{
      host_id: "lesson-concurrency-#{suffix}",
      client_id: "host:lesson-concurrency-#{suffix}",
      scope: "personal",
      namespace: "private"
    }
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp cleanup_on_exit(partition) do
    on_exit(fn ->
      unboxed(fn ->
        repo().query!("ALTER TABLE bpm_memory_evidence DISABLE TRIGGER USER")
        repo().query!("ALTER TABLE bpm_memory_remember_requests DISABLE TRIGGER USER")
        repo().query!("ALTER TABLE memory_audit_log DISABLE TRIGGER USER")

        ids =
          repo().all(
            from(m in Memory,
              where: m.host_id == ^partition.host_id and m.client_id == ^partition.client_id,
              select: m.id
            )
          )

        try do
          repo().delete_all(
            from(a in "memory_audit_log",
              where: fragment("?->>'host_id'", a.metadata) == ^partition.host_id
            )
          )

          repo().delete_all(from(l in Lesson, where: l.memory_id in ^ids))
          repo().delete_all(from(e in Evidence, where: e.memory_id in ^ids))
          repo().delete_all(from(r in RememberRequest, where: r.memory_id in ^ids))
          repo().delete_all(from(m in Memory, where: m.id in ^ids))

          repo().delete_all(
            from(s in ProjectedSession,
              where: s.host_id == ^partition.host_id and s.client_id == ^partition.client_id
            )
          )
        after
          repo().query!("ALTER TABLE memory_audit_log ENABLE TRIGGER USER")
          repo().query!("ALTER TABLE bpm_memory_remember_requests ENABLE TRIGGER USER")
          repo().query!("ALTER TABLE bpm_memory_evidence ENABLE TRIGGER USER")
        end
      end)
    end)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
