defmodule Backplane.Memory.CrystalsTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Crystals, Ingest}
  alias Backplane.Memory.Crystals.{Crystal, ProjectionStore, SourceEvent, SourceSummary}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Projections.{Rebuild, Source, State}
  alias Backplane.Memory.Recall.{Channels, QueryPlan}
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.SummaryWorker
  alias Backplane.Memory.Workers.CrystalWorker

  defmodule ProductionRepo do
    def config, do: [pool: DBConnection.ConnectionPool]
  end

  setup do
    previous = Application.get_env(:backplane_memory, :crystal_task_supervisor)
    supervisor = start_supervised!({Task.Supervisor, name: unique_supervisor()})
    Application.put_env(:backplane_memory, :crystal_task_supervisor, supervisor)

    on_exit(fn ->
      restore_supervisor(
        :crystal_task_supervisor,
        previous,
        Backplane.Memory.Crystal.TaskSupervisor
      )
    end)

    :ok
  end

  test "session builder atomically creates an episodic crystal with immutable exact provenance" do
    input = closed_session("host-crystal", unique("session"), "project-a", "Changed lib/a.ex")
    summary = summarize(input)

    assert {:ok, %Crystal{} = crystal} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    assert crystal.source_session_id == input.session_id
    assert crystal.processing_version == "crystal-v1"
    assert crystal.status == "complete"
    assert crystal.input_revision == input.input_revision
    assert byte_size(crystal.output_revision) == 64
    assert crystal.narrative =~ "Session #{input.session_id}"
    assert crystal.files_affected == ["lib/a.ex"]

    memory = repo().get!(Memory, crystal.memory_id)
    assert memory.memory_type == "episodic"
    assert memory.host_id == input.host_id
    assert memory.client_id == "host:#{input.host_id}"
    assert memory.scope == "private"
    assert memory.namespace == "private"
    assert memory.session_id == input.session_id
    assert memory.content =~ crystal.narrative

    assert [%SourceSummary{summary_id: summary_id}] =
             repo().all(from(link in SourceSummary, where: link.crystal_id == ^crystal.id))

    assert summary_id == summary.id

    linked_event_ids =
      SourceEvent
      |> where([link], link.crystal_id == ^crystal.id)
      |> order_by([link], asc: link.event_id)
      |> select([link], link.event_id)
      |> repo().all()

    raw_event_ids =
      Event
      |> where([event], event.host_id == ^input.host_id and event.session_id == ^input.session_id)
      |> order_by([event], asc: event.id)
      |> select([event], event.id)
      |> repo().all()

    assert linked_event_ids == raw_event_ids
    assert length(raw_event_ids) == 3

    assert_raise Ecto.ConstraintError, fn ->
      repo().update!(
        Ecto.Changeset.change(hd(repo().all(SourceEvent)), event_id: Ecto.UUID.generate())
      )
    end
  end

  test "crystal source links reject update delete and truncate" do
    input = closed_session("host-immutable", unique("session"), "p", "outcome")
    summarize(input)

    assert {:ok, _crystal} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")

    for sql <- [
          "UPDATE memory_crystal_source_events SET inserted_at = now()",
          "DELETE FROM memory_crystal_source_events",
          "TRUNCATE memory_crystal_source_events",
          "UPDATE memory_crystal_source_summaries SET inserted_at = now()",
          "DELETE FROM memory_crystal_source_summaries",
          "TRUNCATE memory_crystal_source_summaries"
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          repo().transaction(fn -> repo().query!(sql) end, mode: :savepoint)
        end

      assert error.postgres[:constraint] == "memory_crystal_source_immutable"
    end
  end

  test "crystal parent invariant is rechecked after memory mutation" do
    input = closed_session("host-parent", unique("session"), "p", "outcome")
    summarize(input)

    assert {:ok, crystal} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    for {column, value} <- [
          {"memory_type", "semantic"},
          {"host_id", "foreign-host"},
          {"client_id", "foreign-client"},
          {"scope", "team"},
          {"namespace", "foreign"},
          {"session_id", "foreign-session"},
          {"lifecycle_state", "candidate"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          repo().transaction(
            fn ->
              repo().query!("UPDATE bpm_memories SET #{column} = $1 WHERE id = $2", [
                value,
                Ecto.UUID.dump!(crystal.memory_id)
              ])

              repo().query!("SET CONSTRAINTS memory_crystal_memory_parent_check IMMEDIATE")
            end,
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == "memory_crystal_parent_check"
    end

    error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(
          fn ->
            repo().query!(
              "UPDATE bpm_memories SET deleted_at = $1, lifecycle_state = 'tombstoned' WHERE id = $2",
              [~U[2026-08-12 00:00:00.000000Z], Ecto.UUID.dump!(crystal.memory_id)]
            )

            repo().query!("SET CONSTRAINTS memory_crystal_memory_parent_check IMMEDIATE")
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.constraint == "memory_crystal_parent_check"
  end

  test "same and concurrent identity returns one row while a new processing version creates a new row" do
    input = closed_session("host-idempotent", unique("session"), "project-a", "stable outcome")
    summarize(input)

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Crystals.build_session(input.host_id, input.session_id, input.input_revision,
            enrich_fn: fn _ -> {:skip, :no_llm} end
          )
        end)
      end)
      |> Task.await_many(10_000)

    ids = Enum.map(results, fn {:ok, crystal} -> crystal.id end)
    assert [_] = Enum.uniq(ids)
    assert repo().aggregate(Crystal, :count) == 1

    assert {:ok, newer} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               processing_version: "crystal-v2",
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    refute newer.id in ids
    assert repo().aggregate(Crystal, :count) == 2
  end

  test "gap-free closed sessions still wait the full grace without losing the work" do
    now = ~U[2026-08-12 12:00:00.000000Z]
    session_id = unique("grace")
    host_id = "host-grace"

    ingest!(event_at(host_id, session_id, "p", 1, "agent.session.started", "start", now))
    ingest!(event_at(host_id, session_id, "p", 2, "agent.session.ended", "done", now))
    assert {:ok, input} = Rebuild.session(host_id, session_id)
    summarize(input)

    args = %{
      "host_id" => host_id,
      "session_id" => session_id,
      "processing_version" => "crystal-v1",
      "input_revision" => input.input_revision
    }

    assert {:snooze, 60} = run_crystal_worker(args, now)
    assert repo().aggregate(Crystal, :count) == 0

    assert :ok = run_crystal_worker(args, DateTime.add(now, 60, :second))
    assert repo().aggregate(Crystal, :count) == 1
  end

  test "normal canonical summary completion enqueues stable crystal work on its isolated queue" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      input = closed_session("host-enqueue", unique("session"), "p", "outcome")
      summarize(input)

      assert [job] = Oban.Testing.all_enqueued(repo(), worker: CrystalWorker)
      assert job.queue == "memory_crystals"
      assert job.max_attempts == 5

      assert job.args == %{
               "host_id" => input.host_id,
               "session_id" => input.session_id,
               "processing_version" => "crystal-v1",
               "input_revision" => input.input_revision
             }
    end)
  end

  test "failed enqueue remains pending and a retry enqueues idempotently" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      input = closed_session("host-enqueue-retry", unique("session"), "p", "outcome")
      subject_id = Source.subject_id!(input.host_id, input.session_id)

      assert {:error, :forced_enqueue_failure} =
               ProjectionStore.enqueue(
                 input.host_id,
                 input.session_id,
                 input.input_revision,
                 fn -> {:error, :forced_enqueue_failure} end
               )

      assert %State{status: "pending", attempt_count: 0} = projection_state(subject_id)

      assert {:ok, first} =
               CrystalWorker.enqueue(input.host_id, input.session_id, input.input_revision)

      assert {:ok, second} =
               CrystalWorker.enqueue(input.host_id, input.session_id, input.input_revision)

      assert first.id == second.id
      assert %State{status: "enqueued", attempt_count: 0} = projection_state(subject_id)
    end)
  end

  test "a stale enqueue cannot regress a newer projection revision or enqueue a job" do
    input = closed_session("host-stale-enqueue", unique("session"), "p", "first")
    summarize(input)

    ingest!(event(input.host_id, input.session_id, "p", 4, "agent.tool.completed", "late"))
    assert {:ok, current} = Rebuild.session(input.host_id, input.session_id)
    summarize(current)
    parent = self()

    assert {:ok, {:stale, %State{input_revision: current_revision, status: "enqueued"}}} =
             ProjectionStore.enqueue(
               input.host_id,
               input.session_id,
               input.input_revision,
               fn ->
                 send(parent, :stale_enqueue_ran)
                 {:ok, :job}
               end
             )

    assert current_revision == current.input_revision
    refute_receive :stale_enqueue_ran

    assert %State{input_revision: ^current_revision, status: "enqueued", last_error: nil} =
             projection_state(input.subject_id)
  end

  test "enqueue rechecks the canonical source revision before its durable callback" do
    input = closed_session("host-enqueue-phase-two", unique("session"), "p", "first")
    parent = self()
    Process.put(:crystal_revision_check, 0)

    source_revision_fn = fn _host_id, _session_id ->
      check = Process.get(:crystal_revision_check)
      Process.put(:crystal_revision_check, check + 1)

      {:ok,
       %{
         input_revision: if(check == 0, do: input.input_revision, else: String.duplicate("a", 64))
       }}
    end

    assert {:ok, {:stale, %State{status: "pending", input_revision: input_revision}}} =
             ProjectionStore.enqueue(
               input.host_id,
               input.session_id,
               input.input_revision,
               fn ->
                 send(parent, :phase_two_enqueue_ran)
                 {:ok, :job}
               end,
               source_revision_fn: source_revision_fn
             )

    assert input_revision == input.input_revision
    refute_receive :phase_two_enqueue_ran
  end

  test "crystal projection state follows enqueue through completion" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      input = closed_session("host-state", unique("session"), "p", "outcome")
      summarize(input)
      subject_id = Source.subject_id!(input.host_id, input.session_id)

      assert %State{
               projector: "crystal",
               subject_type: "captured_session",
               subject_id: ^subject_id,
               processing_version: "crystal-v1",
               input_revision: input_revision,
               status: "enqueued",
               attempt_count: 0,
               last_error: nil
             } = projection_state(subject_id)

      assert input_revision == input.input_revision
      assert :ok = run_crystal_worker(worker_args(input), ~U[2026-08-12 20:00:00.000000Z])

      assert %State{
               status: "complete",
               input_revision: ^input_revision,
               output_revision: output_revision,
               attempt_count: 1,
               last_error: nil
             } = projection_state(subject_id)

      assert is_binary(output_revision)
      assert byte_size(output_revision) == 64
    end)
  end

  test "sandbox authorization bypasses production pools" do
    assert :ok = CrystalWorker.allow_sandbox(self(), ProductionRepo)
  end

  test "sandbox authorization normalizes first and repeated allowances" do
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(repo())

    on_exit(fn ->
      if Process.alive?(sandbox_owner) do
        Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner)
      end
    end)

    {task_pid, task_ref} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
    end)

    assert :ok = CrystalWorker.allow_sandbox(task_pid, repo())
    assert :ok = CrystalWorker.allow_sandbox(task_pid, repo())

    send(task_pid, :stop)
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}
  end

  test "crystal run authorizes its build task with the real sandbox callback" do
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(repo())

    on_exit(fn ->
      if Process.alive?(sandbox_owner) do
        Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner)
      end
    end)

    input = closed_session("host-real-sandbox", unique("session"), "p", "sandbox outcome")
    summarize(input)
    subject_id = Source.subject_id!(input.host_id, input.session_id)

    assert :ok =
             CrystalWorker.run(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               enforce_feature_gate: false
             )

    assert %State{status: "complete", attempt_count: 1, last_error: nil} =
             projection_state(subject_id)
  end

  test "sandbox authorization reports when no caller owns the sandbox" do
    parent = self()

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        send(parent, {
          :sandbox_authorization,
          self(),
          CrystalWorker.allow_sandbox(self(), repo())
        })
      end)

    assert_receive {:sandbox_authorization, ^caller_pid, {:error, :sandbox_owner_not_found}}

    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}
  end

  test "sandbox authorization failure stops the waiting build and records failure" do
    input = closed_session("host-sandbox", unique("session"), "p", "private sandbox payload")
    summarize(input)
    subject_id = Source.subject_id!(input.host_id, input.session_id)
    parent = self()

    assert {:error, :sandbox_owner_not_found} =
             CrystalWorker.run(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               sandbox_allow_fn: fn task_pid ->
                 task_ref = Process.monitor(task_pid)
                 send(parent, {:crystal_waiting_task, task_pid, task_ref})
                 {:error, :sandbox_owner_not_found}
               end,
               build_fn: fn ->
                 send(parent, :crystal_build_ran)
                 :ok
               end
             )

    assert_receive {:crystal_waiting_task, task_pid, task_ref}
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}
    refute Process.alive?(task_pid)
    refute_receive :crystal_build_ran

    assert %State{
             status: "failed",
             attempt_count: 1,
             last_error: "sandbox_owner_not_found"
           } = projection_state(subject_id)
  end

  test "invalid sandbox authorization result stops the waiting build and records failure" do
    input = closed_session("host-sandbox-invalid", unique("session"), "p", "invalid sandbox")
    summarize(input)
    subject_id = Source.subject_id!(input.host_id, input.session_id)
    parent = self()

    assert {:error, {:sandbox_allow_failed, :invalid_authorization}} =
             CrystalWorker.run(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               sandbox_allow_fn: fn task_pid ->
                 task_ref = Process.monitor(task_pid)
                 send(parent, {:invalid_sandbox_task, task_pid, task_ref})
                 :invalid_authorization
               end,
               build_fn: fn ->
                 send(parent, :invalid_sandbox_build_ran)
                 :ok
               end
             )

    assert_receive {:invalid_sandbox_task, task_pid, task_ref}
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}
    refute Process.alive?(task_pid)
    refute_receive :invalid_sandbox_build_ran

    assert %State{status: "failed", attempt_count: 1, last_error: "crystallization_failed"} =
             projection_state(subject_id)
  end

  test "sandbox authorization exceptions stop the waiting build before reraising" do
    input = closed_session("host-sandbox-raise", unique("session"), "p", "sandbox exception")
    summarize(input)
    parent = self()

    assert_raise RuntimeError, "forced sandbox authorization failure", fn ->
      CrystalWorker.run(
        worker_args(input),
        ~U[2026-08-12 20:00:00.000000Z],
        sandbox_allow_fn: fn task_pid ->
          task_ref = Process.monitor(task_pid)
          send(parent, {:raising_sandbox_task, task_pid, task_ref})
          raise "forced sandbox authorization failure"
        end,
        build_fn: fn ->
          send(parent, :raising_sandbox_build_ran)
          :ok
        end
      )
    end

    assert_receive {:raising_sandbox_task, task_pid, task_ref}

    try do
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}
      refute Process.alive?(task_pid)
      refute_receive :raising_sandbox_build_ran
    after
      if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
    end
  end

  test "crystal execution timeout kills the supervised crystallization and records failure" do
    input = closed_session("host-timeout", unique("session"), "p", "private timeout payload")
    summarize(input)
    subject_id = Source.subject_id!(input.host_id, input.session_id)
    parent = self()

    assert {:error, :execution_timeout} =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               timeout_ms: 10,
               build_fn: fn ->
                 send(parent, {:crystal_task, self()})
                 Process.sleep(:infinity)
               end
             )

    assert_receive {:crystal_task, task_pid}
    refute Process.alive?(task_pid)

    assert %State{status: "failed", attempt_count: 1, last_error: "execution_timeout"} =
             projection_state(subject_id)

    assert {:error, {:provider_error, "private detail"}} =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               attempt: 5,
               max_attempts: 5,
               build_fn: fn -> {:error, {:provider_error, "private detail"}} end
             )

    assert %State{
             status: "dead_letter",
             attempt_count: 2,
             last_error: "crystallization_failed"
           } = projection_state(subject_id)
  end

  test "crystal telemetry contains identifiers and classifications but no private failure data" do
    input = closed_session("host-telemetry", unique("session"), "p", "private source text")
    summarize(input)
    handler_id = "crystal-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:backplane, :memory, :crystal, :start],
          [:backplane, :memory, :crystal, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:crystal_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, {:provider_error, "sk-secret-private"}} =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               job_id: 42,
               queue: "memory_crystals",
               attempt: 2,
               max_attempts: 5,
               build_fn: fn -> {:error, {:provider_error, "sk-secret-private"}} end
             )

    for suffix <- [:start, :stop] do
      assert_receive {:crystal_telemetry, [:backplane, :memory, :crystal, ^suffix], _measurements,
                      metadata}

      assert metadata.host_id == input.host_id
      assert metadata.session_id == input.session_id
      assert metadata.job_id == 42
      assert metadata.attempt == 2
      refute inspect(metadata) =~ "sk-secret-private"
      refute Map.has_key?(metadata, :content)
      refute Map.has_key?(metadata, :error)
    end
  end

  test "a source revision that becomes stale during build is skipped, not left running" do
    input = closed_session("host-build-stale", unique("session"), "p", "first")
    summarize(input)
    handler_id = "crystal-stale-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :crystal, :stop],
        fn event, measurements, metadata, _ ->
          send(parent, {:crystal_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               build_session_fn: fn host_id, session_id, expected_revision ->
                 ingest!(event(host_id, session_id, "p", 4, "agent.tool.completed", "late"))

                 assert {:ok, _projection} = Rebuild.session(host_id, session_id)
                 Crystals.build_session(host_id, session_id, expected_revision)
               end
             )

    assert %State{
             input_revision: input_revision,
             status: "skipped",
             attempt_count: 1,
             last_error: "stale_input_revision"
           } = projection_state(input.subject_id)

    assert input_revision == input.input_revision

    assert_receive {:crystal_telemetry, [:backplane, :memory, :crystal, :stop], _measurements,
                    %{classification: :skipped}}
  end

  test "a newer projection between preflight and running skips execution and telemetry" do
    input = closed_session("host-running-race", unique("session"), "p", "first")
    summarize(input)
    parent = self()
    handler_id = "crystal-running-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :crystal, :stop],
        fn event, measurements, metadata, _ ->
          send(parent, {:crystal_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               before_running: fn ->
                 ingest!(
                   event(
                     input.host_id,
                     input.session_id,
                     "p",
                     4,
                     "agent.tool.completed",
                     "late"
                   )
                 )

                 assert {:ok, current} = Rebuild.session(input.host_id, input.session_id)

                 assert {:ok, :newer_job} =
                          ProjectionStore.enqueue(
                            input.host_id,
                            input.session_id,
                            current.input_revision,
                            fn -> {:ok, :newer_job} end
                          )

                 send(parent, {:newer_revision, current.input_revision})
                 :ok
               end,
               build_fn: fn ->
                 send(parent, :stale_build_ran)
                 :ok
               end
             )

    assert_receive {:newer_revision, newer_revision}
    refute_receive :stale_build_ran

    assert %State{input_revision: ^newer_revision, status: "enqueued", last_error: nil} =
             projection_state(input.subject_id)

    assert_receive {:crystal_telemetry, [:backplane, :memory, :crystal, :stop], _measurements,
                    %{classification: :skipped}}
  end

  test "a source-only revision after crystal persistence makes completion telemetry skipped" do
    input = closed_session("host-complete-race", unique("session"), "p", "first")
    summarize(input)
    parent = self()
    handler_id = "crystal-complete-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :crystal, :stop],
        fn event, measurements, metadata, _ ->
          send(parent, {:crystal_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             run_crystal_worker(
               worker_args(input),
               ~U[2026-08-12 20:00:00.000000Z],
               build_session_fn: fn host_id, session_id, expected_revision ->
                 assert {:ok, crystal} =
                          Crystals.build_session(host_id, session_id, expected_revision)

                 ingest!(event(host_id, session_id, "p", 4, "agent.tool.completed", "late"))
                 assert {:ok, current} = Rebuild.session(host_id, session_id)

                 send(parent, {:newer_revision, current.input_revision})
                 {:ok, crystal}
               end
             )

    assert_receive {:newer_revision, newer_revision}
    assert repo().aggregate(Crystal, :count) == 1

    assert %State{
             input_revision: old_revision,
             status: "skipped",
             last_error: "stale_input_revision"
           } =
             projection_state(input.subject_id)

    assert old_revision == input.input_revision
    refute old_revision == newer_revision

    assert_receive {:crystal_telemetry, [:backplane, :memory, :crystal, :stop], _measurements,
                    %{classification: :skipped}}

    assert {:error, :stale_input_revision} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    assert {:ok, current} = Rebuild.session(input.host_id, input.session_id)
    assert current.input_revision == newer_revision
    summarize(current)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} =
               CrystalWorker.enqueue(input.host_id, input.session_id, current.input_revision)
    end)

    assert :ok = run_crystal_worker(worker_args(current), ~U[2026-08-12 20:01:00.000000Z])

    assert %State{
             input_revision: ^newer_revision,
             status: "skipped",
             last_error: "stale_input_revision"
           } = projection_state(input.subject_id)

    assert [%Crystal{input_revision: ^old_revision}] = repo().all(Crystal)
  end

  test "invalid enrichment degrades field by field and never stores private raw content" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      input =
        closed_session(
          "host-private",
          unique("session"),
          "p",
          "safe result sk-secretvalue123456789"
        )

      summarize(input)

      assert {:ok, crystal} =
               Crystals.build_session(input.host_id, input.session_id, input.input_revision,
                 enrich_fn: fn _ ->
                   {:ok,
                    %{
                      "title" => "LLM title",
                      "narrative" => nil,
                      "key_outcomes" => ["useful", 42],
                      "decisions" => String.duplicate("x", 70_000),
                      "files_affected" => [],
                      "unresolved_items" => ["<private>do not store</private>"]
                    }, "model-a"}
                 end
               )

      assert crystal.title == "LLM title"
      assert crystal.narrative =~ "[REDACTED]"
      assert crystal.key_outcomes == ["useful"]
      assert crystal.decisions == []
      assert crystal.files_affected == ["lib/a.ex"]
      assert crystal.unresolved_items == ["[REDACTED]"]
      refute crystal.narrative =~ "sk-secretvalue"
      refute inspect(crystal) =~ "do not store"
    end)
  end

  test "stale worker is effect-free and current concurrent workers converge" do
    input = closed_session("host-worker-race", unique("session"), "p", "first")
    summarize(input)

    ingest!(event(input.host_id, input.session_id, "p", 4, "agent.tool.completed", "late"))
    assert {:ok, current} = Rebuild.session(input.host_id, input.session_id)
    summarize(current)

    stale = worker_args(input)
    assert :ok = run_crystal_worker(stale, ~U[2026-08-12 20:00:00.000000Z])
    assert repo().aggregate(Crystal, :count) == 0

    assert %State{
             input_revision: current_revision,
             status: "enqueued",
             last_error: nil
           } =
             projection_state(input.subject_id)

    assert current_revision == current.input_revision

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          run_crystal_worker(worker_args(current), ~U[2026-08-12 20:00:00.000000Z])
        end)
      end)
      |> Task.await_many(10_000)

    assert results == [:ok, :ok, :ok, :ok]
    assert repo().aggregate(Crystal, :count) == 1
  end

  test "a stale transition cannot overwrite a newer crystal projection revision" do
    input = closed_session("host-transition-race", unique("session"), "p", "first")
    summarize(input)

    ingest!(event(input.host_id, input.session_id, "p", 4, "agent.tool.completed", "late"))
    assert {:ok, current} = Rebuild.session(input.host_id, input.session_id)
    summarize(current)

    assert {:ok, {:stale, %State{input_revision: current_revision, status: "enqueued"}}} =
             ProjectionStore.failed(
               input.host_id,
               input.session_id,
               input.input_revision,
               :execution_timeout
             )

    assert current_revision == current.input_revision
    assert %State{status: "enqueued", last_error: nil} = projection_state(input.subject_id)
  end

  test "crystal search and general recall return typed exact-partition provenance" do
    input =
      closed_session(
        "host-recall",
        unique("session"),
        "project-recall",
        "distinctive crystalline outcome"
      )

    summary = summarize(input)

    assert {:ok, crystal} =
             Crystals.build_session(input.host_id, input.session_id, input.input_revision,
               enrich_fn: fn _ -> {:skip, :no_llm} end
             )

    partition = %{
      host_id: input.host_id,
      client_id: "host:#{input.host_id}",
      scope: "private",
      namespace: "private"
    }

    assert {:ok, [%Crystal{id: crystal_id}]} =
             Crystals.search("crystalline outcome", partition)

    assert crystal_id == crystal.id
    assert {:ok, []} = Crystals.search("crystalline outcome", %{partition | client_id: "foreign"})

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(partition, %{query: "crystalline outcome"}))

    assert {:ok, rows} = Channels.fts(plan, 10)

    assert Enum.any?(rows, fn {candidate, _score} ->
             candidate.kind == :crystal and candidate.id == crystal.memory_id and
               candidate.memory_type == :episodic and candidate.session_id == input.session_id and
               candidate.source_refs == [%{type: :summary, id: summary.id}]
           end)
  end

  defp closed_session(host_id, session_id, project, content) do
    ingest!(event(host_id, session_id, project, 1, "agent.session.started", "start"))

    ingest!(
      event(host_id, session_id, project, 2, "agent.tool.completed", content)
      |> Map.put("payload", %{
        "source" => %{"message" => content, "file_paths" => ["lib/a.ex"]}
      })
      |> refresh_payload_hash()
    )

    ingest!(event(host_id, session_id, project, 3, "agent.session.ended", "done"))
    {:ok, result} = Rebuild.session(host_id, session_id)
    result
  end

  defp summarize(input) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok =
               SummaryWorker.perform(%Oban.Job{
                 args: %{
                   "host_id" => input.host_id,
                   "session_id" => input.session_id,
                   "processing_version" => "summary-v1",
                   "input_revision" => input.input_revision
                 }
               })
    end)

    repo().one!(
      from(summary in Summary,
        where:
          summary.host_id == ^input.host_id and summary.session_id == ^input.session_id and
            summary.processing_version == "summary-v1"
      )
    )
  end

  defp event(host, session, project, sequence, type, content) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host,
      "client_id" => "client-#{host}",
      "scope" => "private",
      "namespace" => "default",
      "session_id" => session,
      "project" => project,
      "sequence" => sequence,
      "event_type" => type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host}:#{session}:#{sequence}:#{type}",
      "payload" => %{"message" => content}
    })
  end

  defp event_at(host, session, project, sequence, type, content, occurred_at) do
    event(host, session, project, sequence, type, content)
    |> Map.put("occurred_at", DateTime.to_iso8601(occurred_at))
    |> Map.put("captured_at", DateTime.to_iso8601(occurred_at))
  end

  defp worker_args(input) do
    %{
      "host_id" => input.host_id,
      "session_id" => input.session_id,
      "processing_version" => "crystal-v1",
      "input_revision" => input.input_revision
    }
  end

  defp run_crystal_worker(args, current_time) do
    run_crystal_worker(args, current_time, enforce_feature_gate: false)
  end

  defp run_crystal_worker(args, current_time, opts) do
    CrystalWorker.run(
      args,
      current_time,
      Keyword.put_new(opts, :sandbox_allow_fn, fn _task_pid -> :ok end)
    )
  end

  defp projection_state(subject_id) do
    repo().one!(
      from(state in State,
        where:
          state.projector == "crystal" and state.subject_type == "captured_session" and
            state.subject_id == ^subject_id
      )
    )
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               %{
                 host_id: event["host_id"],
                 auth_token_id: "token-#{event["host_id"]}",
                 scopes: ["host_agent.capture"]
               },
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => event["host_id"],
                 "events" => [event]
               }
             )
  end

  defp refresh_payload_hash(event) do
    Map.put(
      event,
      "payload_hash",
      Backplane.Memory.Ingest.EventValidator.payload_hash(event["payload"])
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_supervisor,
    do: String.to_atom("crystal-test-#{System.unique_integer([:positive])}")

  defp restore_supervisor(key, previous, default) when is_pid(previous),
    do: Application.put_env(:backplane_memory, key, default)

  defp restore_supervisor(key, nil, _default), do: Application.delete_env(:backplane_memory, key)

  defp restore_supervisor(key, previous, _default),
    do: Application.put_env(:backplane_memory, key, previous)
end
