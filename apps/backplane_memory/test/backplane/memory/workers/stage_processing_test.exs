defmodule Backplane.Memory.Workers.StageProcessingTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Operations.{Consolidation, Rollout}
  alias Backplane.Memory.Projections.{ProjectedSession, Rebuild, Source, State}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  alias Backplane.Memory.Workers.{
    EpisodicWorker,
    GraphExtractWorker,
    ProceduralWorker,
    ProjectionRepairWorker,
    StageResumeWorker,
    SummaryWorker,
    WindowSummaryWorker
  }

  @keys ~w(memory.pipeline.enabled memory.window_summaries.enabled
    memory.session_summary.enabled memory.fact_extraction.enabled
    memory.procedure_extraction.enabled memory.relation_classifier.enabled memory.llm_model memory.crystals_enabled)

  defmodule Model do
    def extract_fact_candidates(_content, bundle, _model) do
      send(self(), :facts_called)

      if Process.get(:disable_during_facts),
        do: :ets.insert(:backplane_settings, {"memory.fact_extraction.enabled", false})

      {:ok,
       Backplane.Memory.FactExtractionFixtures.proposals(
         bundle["assertion_units"] |> Enum.take(10) |> Enum.map(& &1["text"]),
         bundle
       )}
    end

    def assess_fact_candidates(_bundle, facts, _model),
      do: {:ok, Backplane.Memory.FactExtractionFixtures.assessment(facts)}

    def extract_procedures(_content) do
      send(self(), :procedures_called)
      {:ok, ["Verify the captured deployment before restart"]}
    end

    def extract_graph(_content) do
      send(self(), :graph_called)

      if Process.get(:graph_failure),
        do: {:error, :invalid_graph_response},
        else: {:ok, %{nodes: [%{key: "backplane", name: "Backplane", type: "Module"}], edges: []}}
    end
  end

  setup do
    settings = Map.new(@keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    previous = Application.get_env(:backplane_memory, :llm_module)
    Enum.each(@keys, &:ets.insert(:backplane_settings, {&1, true}))
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})
    :ets.insert(:backplane_settings, {"memory.crystals_enabled", false})
    Application.put_env(:backplane_memory, :llm_module, Model)

    on_exit(fn ->
      Enum.each(settings, fn {key, entries} ->
        :ets.delete(:backplane_settings, key)
        Enum.each(entries, &:ets.insert(:backplane_settings, &1))
      end)

      if previous,
        do: Application.put_env(:backplane_memory, :llm_module, previous),
        else: Application.delete_env(:backplane_memory, :llm_module)
    end)

    :ok
  end

  test "queued summary disablement is durable and re-enable resumes the same revision" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-disabled", 3)

      assert {:ok, job} =
               SummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      :ets.insert(:backplane_settings, {"memory.session_summary.enabled", false})
      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      assert state(session, "summary").status == "skipped_disabled"
      assert repo().aggregate(Summary, :count) == 0

      :ets.insert(:backplane_settings, {"memory.session_summary.enabled", true})
      assert {:ok, _} = StageResumeWorker.perform(%Styx.Job{args: %{}})
      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      summary = repo().one!(from(s in Summary, where: s.processing_version == "summary-v1"))
      assert summary.content =~ "generation_mode=deterministic"
      assert summary.content =~ "generation_reason=canonical_evidence"

      :ets.insert(:backplane_settings, {"memory.session_summary.enabled", false})
      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      assert state(session, "summary").status == "complete"
      assert repo().get!(Summary, summary.id) == summary
    end)
  end

  test "facts honor disablement before generation and before fenced persistence" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-facts", 3)

      assert {:ok, job} =
               SummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      assert [facts] = Styx.Testing.all_enqueued(repo(), worker: EpisodicWorker)
      :ets.insert(:backplane_settings, {"memory.fact_extraction.enabled", false})
      assert :ok = EpisodicWorker.perform(facts)
      refute_received :facts_called
      assert state(session, "episodic").status == "skipped_disabled"

      :ets.insert(:backplane_settings, {"memory.fact_extraction.enabled", true})
      Process.put(:disable_during_facts, true)
      assert :ok = EpisodicWorker.perform(facts)
      assert_received :facts_called
      assert repo().aggregate(Memory, :count) == 0
      assert state(session, "episodic").status == "skipped_disabled"
    end)
  end

  test "normal summary chain durably schedules qualifying procedure and graph work" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-chain", 3)

      assert {:ok, job} =
               SummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      assert [facts] = Styx.Testing.all_enqueued(repo(), worker: EpisodicWorker)
      assert :ok = EpisodicWorker.perform(facts)
      assert [procedure] = Styx.Testing.all_enqueued(repo(), worker: ProceduralWorker)
      assert [graph] = Styx.Testing.all_enqueued(repo(), worker: GraphExtractWorker)
      assert procedure.args["memory_space_id"] == session.memory_space_id
      assert procedure.args["project"] == "stage-project"
      :ets.insert(:backplane_settings, {"memory.procedure_extraction.enabled", false})
      assert :ok = ProceduralWorker.perform(procedure)
      refute_received :procedures_called
      :ets.insert(:backplane_settings, {"memory.procedure_extraction.enabled", true})
      assert :ok = ProceduralWorker.perform(procedure)
      assert {:ok, _} = GraphExtractWorker.perform(graph)
      assert_received :procedures_called
      assert_received :graph_called
      assert repo().aggregate(from(m in Memory, where: m.memory_type == "semantic"), :count) == 10

      assert repo().aggregate(from(m in Memory, where: m.memory_type == "procedural"), :count) ==
               1
    end)
  end

  test "windows bound exact source links and preserve session-summary identity" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-windows", 101)

      assert {:ok, enumeration} =
               WindowSummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = WindowSummaryWorker.perform(enumeration)

      windows =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.filter(&(&1.args["mode"] == "window"))

      assert length(windows) == 2

      Enum.each(windows, fn job ->
        assert :ok = WindowSummaryWorker.perform(repo().get!(Styx.Job, job.id))
      end)

      summaries =
        repo().all(from(s in Summary, where: s.processing_version == "window-summary-v1"))

      assert length(summaries) == 2
      assert Enum.all?(summaries, &(&1.subject_id != session.subject_id))

      assert Enum.all?(
               summaries,
               &String.contains?(&1.content, "generation_reason=evidence_window")
             )

      assert Enum.sort(
               Enum.map(summaries, fn summary ->
                 repo().aggregate(
                   from(link in SourceEvent, where: link.summary_id == ^summary.id),
                   :count
                 )
               end)
             ) == [1, 100]

      Enum.each(windows, fn job ->
        assert :ok = WindowSummaryWorker.perform(repo().get!(Styx.Job, job.id))
      end)

      assert repo().aggregate(Summary, :count) == 2
    end)
  end

  test "automatic reconciliation never renews a failed graph retry budget but operator retry and new input work" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-graph-budget", 3)

      assert {:ok, summary} =
               SummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, summary.id))
      assert [facts] = Styx.Testing.all_enqueued(repo(), worker: EpisodicWorker)
      assert :ok = EpisodicWorker.perform(facts)
      assert [graph] = Styx.Testing.all_enqueued(repo(), worker: GraphExtractWorker)
      Process.put(:graph_failure, true)

      for attempt <- 1..3 do
        assert {:error, :invalid_graph_response} =
                 GraphExtractWorker.perform(%{graph | attempt: attempt, max_attempts: 3})

        assert state(session, "graph").attempt_count == attempt
        # A failed state must not create another job even before Styx finishes its budget.
        assert {:ok, _} = StageResumeWorker.reconcile_session(session)

        assert repo().aggregate(from(j in Styx.Job, where: j.worker == ^graph.worker), :count) ==
                 1
      end

      assert state(session, "graph").status == "dead_letter"
      repo().update_all(from(j in Styx.Job, where: j.id == ^graph.id), set: [state: "discarded"])
      for _ <- 1..3, do: assert({:ok, _} = StageResumeWorker.perform(%Styx.Job{args: %{}}))
      assert repo().aggregate(from(j in Styx.Job, where: j.worker == ^graph.worker), :count) == 1
      assert {:ok, _} = GraphExtractWorker.enqueue(session.session_id, partition(session))
      assert repo().aggregate(from(j in Styx.Job, where: j.worker == ^graph.worker), :count) == 1

      assert {:ok, _} = Consolidation.enqueue(session.session_id, partition(session))
      assert [retry] = Styx.Testing.all_enqueued(repo(), worker: GraphExtractWorker)
      assert retry.id != graph.id
      Process.delete(:graph_failure)
      assert {:ok, %{nodes_extracted: 1}} = GraphExtractWorker.perform(retry)
      assert state(session, "graph").status == "complete"

      ingest_events!(session.host_id, session.session_id, [4], 4)
      assert {:ok, _} = Rebuild.session(session.host_id, session.session_id)
      current = repo().get!(ProjectedSession, session.subject_id)
      assert current.input_revision != session.input_revision
      assert {:ok, next} = GraphExtractWorker.enqueue(session.session_id, partition(current))
      assert next.args["input_revision"] == current.input_revision
      assert next.id != retry.id
    end)
  end

  test "completed window enumerators and ranges are not recreated for unchanged input" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-window-complete", 3)
      job = window_job!(session)
      assert :ok = WindowSummaryWorker.perform(job)

      [enumeration] =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.filter(&(&1.args["mode"] == "enumerate"))

      repo().update_all(from(j in Styx.Job, where: j.worker == ^job.worker),
        set: [state: "completed"]
      )

      before_count = repo().aggregate(from(j in Styx.Job, where: j.worker == ^job.worker), :count)
      for _ <- 1..3, do: assert({:ok, _} = StageResumeWorker.perform(%Styx.Job{args: %{}}))
      assert :ok = WindowSummaryWorker.perform(enumeration)
      assert {:ok, _} = Consolidation.enqueue(session.session_id, partition(session))

      assert repo().aggregate(from(j in Styx.Job, where: j.worker == ^job.worker), :count) ==
               before_count

      assert window_state!().attempt_count == 1

      assert repo().aggregate(
               from(s in Summary, where: s.processing_version == "window-summary-v1"),
               :count
             ) == 1
    end)
  end

  test "disabled window work resumes after its completed enumeration without recreating complete ranges" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-window-resume", 3)
      job = window_job!(session)
      :ets.insert(:backplane_settings, {"memory.window_summaries.enabled", false})
      assert :ok = WindowSummaryWorker.perform(job)
      assert window_state!().status == "skipped_disabled"

      repo().update_all(from(j in Styx.Job, where: j.worker == ^job.worker),
        set: [state: "completed"]
      )

      :ets.insert(:backplane_settings, {"memory.window_summaries.enabled", true})
      assert {:ok, _} = StageResumeWorker.reconcile_session(session)
      assert [enumeration] = Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
      assert :ok = WindowSummaryWorker.perform(enumeration)

      assert [retry] =
               Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
               |> Enum.filter(&(&1.args["mode"] == "window"))

      assert retry.id != job.id
      assert :ok = WindowSummaryWorker.perform(retry)
      assert window_state!().status == "complete"
    end)
  end

  test "discarded window ranges require an explicit operator retry at the same revision" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-window-retry", 3)
      job = window_job!(session)

      repo().query!(
        "ALTER TABLE memory_summaries ADD CONSTRAINT reject_retry_window CHECK (processing_version <> 'window-summary-v1')"
      )

      try do
        assert_raise Ecto.ConstraintError, fn ->
          WindowSummaryWorker.perform(%{job | attempt: 3, max_attempts: 3})
        end
      after
        repo().query!("ALTER TABLE memory_summaries DROP CONSTRAINT reject_retry_window")
      end

      assert window_state!().status == "dead_letter"

      [enumeration] =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.filter(&(&1.args["mode"] == "enumerate"))

      repo().update_all(from(j in Styx.Job, where: j.worker == ^job.worker),
        set: [state: "completed"]
      )

      repo().update_all(from(j in Styx.Job, where: j.id == ^job.id), set: [state: "discarded"])
      assert {:ok, _} = StageResumeWorker.reconcile_session(session)
      assert :ok = WindowSummaryWorker.perform(enumeration)
      assert [] = Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)

      assert {:ok, _} = Consolidation.enqueue(session.session_id, partition(session))
      assert [retry_enumeration] = Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
      assert :ok = WindowSummaryWorker.perform(retry_enumeration)

      assert [retry] =
               Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
               |> Enum.filter(&(&1.args["mode"] == "window"))

      assert retry.id != job.id
      assert :ok = WindowSummaryWorker.perform(retry)
      assert window_state!().status == "complete"

      assert repo().aggregate(
               from(s in Summary, where: s.processing_version == "window-summary-v1"),
               :count
             ) == 1
    end)
  end

  test "window disablement and late-event revisions never publish the stale range" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-late-window", 3, omit: [2])

      assert {:ok, enumeration} =
               WindowSummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = WindowSummaryWorker.perform(enumeration)

      old =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.find(&(&1.args["mode"] == "window"))

      :ets.insert(:backplane_settings, {"memory.window_summaries.enabled", false})
      assert :ok = WindowSummaryWorker.perform(old)
      assert repo().aggregate(Summary, :count) == 0
      :ets.insert(:backplane_settings, {"memory.window_summaries.enabled", true})
      ingest_events!(session.host_id, session.session_id, [2], 3)
      assert :ok = WindowSummaryWorker.perform(old)
      assert repo().aggregate(Summary, :count) == 0
      assert {:ok, updated} = Rebuild.session(session.host_id, session.session_id)

      assert {:ok, enumeration} =
               WindowSummaryWorker.enqueue(
                 updated.host_id,
                 updated.session_id,
                 updated.input_revision,
                 partition(session)
               )

      assert :ok = WindowSummaryWorker.perform(enumeration)

      windows =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.filter(&(&1.args["mode"] == "window"))

      Enum.each(windows, fn job ->
        assert :ok = WindowSummaryWorker.perform(repo().get!(Styx.Job, job.id))
      end)

      assert [%Summary{observation_count: 3}] = repo().all(Summary)
    end)
  end

  test "window persistence failures record attempts and recover without partial artifacts" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-window-failure", 3)
      job = window_job!(session)
      constraint = "memory_summaries_test_reject_window"

      repo().query!(
        "ALTER TABLE memory_summaries ADD CONSTRAINT #{constraint} CHECK (processing_version <> 'window-summary-v1')"
      )

      try do
        assert_raise Ecto.ConstraintError, fn -> WindowSummaryWorker.perform(job) end

        assert %State{status: "failed", attempt_count: 1, last_error: "window_persistence_failed"} =
                 window_state!()

        assert repo().aggregate(Summary, :count) == 0
        assert repo().aggregate(SourceEvent, :count) == 0

        assert_raise Ecto.ConstraintError, fn ->
          WindowSummaryWorker.perform(%{job | attempt: 3, max_attempts: 3})
        end

        assert %State{status: "dead_letter", attempt_count: 2} = window_state!()
      after
        repo().query!("ALTER TABLE memory_summaries DROP CONSTRAINT #{constraint}")
      end

      assert :ok = WindowSummaryWorker.perform(job)
      assert %State{status: "complete", attempt_count: 3, last_error: nil} = window_state!()
      assert repo().aggregate(Summary, :count) == 1
      assert repo().aggregate(SourceEvent, :count) == 3
      assert :ok = WindowSummaryWorker.perform(job)
      assert %State{status: "complete", attempt_count: 3} = window_state!()
    end)
  end

  test "window supersession preserves source history and rejects stale or foreign jobs" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-window-history", 3, omit: [2])
      old = window_job!(session)
      assert :ok = WindowSummaryWorker.perform(old)
      first = repo().one!(Summary)
      ingest_events!(session.host_id, session.session_id, [2], 3)
      assert {:ok, _} = Rebuild.session(session.host_id, session.session_id)
      current = repo().get!(ProjectedSession, session.subject_id)
      new = window_job!(current)
      refute new.args["input_revision"] == old.args["input_revision"]
      assert :ok = WindowSummaryWorker.perform(new)
      second = repo().one!(from(s in Summary, where: s.processing_version == "window-summary-v1"))
      history = repo().get!(Summary, first.id)
      assert history.superseded_by_input_revision == second.input_revision
      assert history.superseded_at
      assert history.content == first.content

      assert repo().aggregate(from(e in SourceEvent, where: e.summary_id == ^first.id), :count) ==
               2

      assert repo().aggregate(from(e in SourceEvent, where: e.summary_id == ^second.id), :count) ==
               3

      assert second.memory_space_id == session.memory_space_id
      assert second.host_id == session.host_id
      assert second.scope == session.scope
      assert second.namespace == session.namespace
      assert second.source_client_id == session.source_client_id

      assert :ok = WindowSummaryWorker.perform(old)
      foreign = canonical_partition("stage-window-foreign", scope: session.scope)
      args = Map.merge(new.args, Map.new(foreign, fn {k, v} -> {to_string(k), v} end))
      assert :ok = WindowSummaryWorker.perform(%Styx.Job{args: args})
      assert repo().aggregate(Summary, :count) == 2
      assert %State{status: "complete", input_revision: revision} = window_state!()
      assert revision == second.input_revision
    end)
  end

  @tag timeout: 180_000
  test "window enumeration continues after 100 ranges without crossing owner partitions" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      # Real ingestion assigns immutable durable positions. 10,001 events
      # produce 101 contiguous windows and exercise the enumeration cursor.
      session = session!("stage-window-page", 10_001)

      _foreign = session!("stage-window-page-foreign", 2)

      assert {:ok, enumeration} =
               WindowSummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = WindowSummaryWorker.perform(enumeration)
      jobs = Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
      assert length(Enum.filter(jobs, &(&1.args["mode"] == "window"))) == 100
      assert [continuation] = Enum.filter(jobs, &Map.has_key?(&1.args, "cursor"))
      assert [_stream, bucket] = continuation.args["cursor"]
      assert bucket == 99
      assert :ok = WindowSummaryWorker.perform(continuation)

      windows =
        Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
        |> Enum.filter(&(&1.args["mode"] == "window"))

      assert length(windows) == 101
      assert length(Enum.uniq_by(windows, &{&1.args["stream_id"], &1.args["bucket"]})) == 101
      assert Enum.sort(Enum.map(windows, & &1.args["bucket"])) == Enum.to_list(0..100)

      assert Enum.all?(
               windows,
               &(&1.args["host_id"] == session.host_id and
                   &1.args["memory_space_id"] == session.memory_space_id and
                   &1.args["client_id"] == session.client_id and
                   &1.args["scope"] == session.scope and
                   &1.args["namespace"] == session.namespace)
             )

      assert :ok = WindowSummaryWorker.perform(continuation)

      assert length(
               Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
               |> Enum.filter(&(&1.args["mode"] == "window"))
             ) == 101
    end)
  end

  test "session consolidation returns revision progress and artifacts without profile jobs" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-consolidate", 3)
      assert {:ok, first} = Consolidation.enqueue(session.session_id, partition(session))
      assert first.input_revision == session.input_revision
      assert first.stages["summary"].status in ["pending", "enqueued"]
      assert [job] = Styx.Testing.all_enqueued(repo(), worker: SummaryWorker)
      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, job.id))
      assert {:ok, second} = Consolidation.enqueue(session.session_id, partition(session))
      assert second.stages["summary"].status == "complete"
      assert length(second.artifact_ids.summaries) == 1
      assert Map.has_key?(second.stages, "procedural")
      assert Map.has_key?(second.stages, "window_summary")
      assert second.artifact_ids.crystals == []
      before_jobs = repo().aggregate(Styx.Job, :count)
      assert {:ok, read_only} = Consolidation.get(session.session_id, partition(session))
      assert read_only.artifact_ids == second.artifact_ids
      assert repo().aggregate(Styx.Job, :count) == before_jobs
      assert length(Styx.Testing.all_enqueued(repo(), worker: SummaryWorker)) == 1

      assert [] ==
               Styx.Testing.all_enqueued(repo(),
                 worker: Backplane.Memory.Workers.ProfileBuildWorker
               )

      foreign = canonical_partition("foreign-stage", scope: session.scope)
      assert {:error, :not_found} = Consolidation.enqueue(session.session_id, foreign)
      assert {:error, :not_found} = Consolidation.get(session.session_id, foreign)
    end)
  end

  test "master disablement blocks manual reconciliation and queued graph calls" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-master-disabled", 3)
      assert {:ok, job} = GraphExtractWorker.enqueue(session.session_id, partition(session))
      :ets.insert(:backplane_settings, {"memory.pipeline.enabled", false})
      assert {:ok, []} = StageResumeWorker.reconcile_session(session)

      assert {:ok, {:skipped, :disabled}} =
               GraphExtractWorker.perform(repo().get!(Styx.Job, job.id))

      refute_received :graph_called
      assert state(session, "graph").status == "skipped_disabled"
      assert {:ok, %{sessions: 0, jobs: 0}} = StageResumeWorker.perform(%Styx.Job{args: %{}})
    end)
  end

  test "no-model work resumes after a model is configured without replacing completed artifacts" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-model-resume", 3)

      assert {:ok, summary_job} =
               SummaryWorker.enqueue(
                 session.host_id,
                 session.session_id,
                 session.input_revision,
                 partition(session)
               )

      assert :ok = SummaryWorker.perform(repo().get!(Styx.Job, summary_job.id))
      assert [facts] = Styx.Testing.all_enqueued(repo(), worker: EpisodicWorker)
      :ets.insert(:backplane_settings, {"memory.llm_model", ""})
      assert :ok = EpisodicWorker.perform(facts)
      assert state(session, "episodic").status == "skipped_no_model"
      refute_received :facts_called
      :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})
      assert {:ok, _} = StageResumeWorker.reconcile_session(session)
      assert :ok = EpisodicWorker.perform(facts)
      assert state(session, "episodic").status == "complete"
      assert_received :facts_called
      :ets.insert(:backplane_settings, {"memory.fact_extraction.enabled", false})
      assert :ok = EpisodicWorker.perform(facts)
      assert state(session, "episodic").status == "complete"
      assert repo().aggregate(Memory, :count) == 10
    end)
  end

  test "reconciliation advances a bounded session cursor" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      session = session!("stage-cursor", 1)
      :ets.insert(:backplane_settings, {"memory.window_summaries.enabled", false})
      :ets.insert(:backplane_settings, {"memory.session_summary.enabled", false})
      attrs = Map.from_struct(session) |> Map.drop([:__meta__])

      for index <- 1..100 do
        host = "cursor-#{index}"

        repo().insert!(
          struct(
            ProjectedSession,
            Map.merge(attrs, %{
              host_id: host,
              subject_id: Source.subject_id!(host, session.session_id)
            })
          )
        )
      end

      assert {:ok, %{sessions: 100, jobs: 0}} = StageResumeWorker.perform(%Styx.Job{args: %{}})
      assert [continuation] = Styx.Testing.all_enqueued(repo(), worker: StageResumeWorker)
      assert is_binary(continuation.args["cursor"])
      assert {:ok, %{sessions: 1, jobs: 0}} = StageResumeWorker.perform(continuation)

      assert {:cancel, :invalid_arguments} =
               StageResumeWorker.perform(%Styx.Job{args: %{"cursor" => 1}})
    end)
  end

  test "canonical projection repair durably dispatches windows before session completion" do
    previous = Application.get_env(:backplane_memory, :projection_repair_enabled)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:backplane_memory, :projection_repair_enabled),
        else: Application.put_env(:backplane_memory, :projection_repair_enabled, previous)
    end)

    Styx.Testing.with_testing_mode(:manual, fn ->
      host = "stage-active-repair"
      session = "active-session"
      ingest_events!(host, session, [1], 2)
      assert [repair] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert :ok = ProjectionRepairWorker.perform(repair)
      assert [_enumeration] = Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
      assert [] = Styx.Testing.all_enqueued(repo(), worker: SummaryWorker)
    end)
  end

  test "rollout advertises effective stage controls and retention has a production schedule" do
    stages = Rollout.state().later
    assert Enum.all?(Enum.take(stages, 4), &(&1.available and &1.effective))

    {_plugin, opts} =
      Application.fetch_env!(:backplane, Styx)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _} -> plugin == Styx.Cron end)

    assert Enum.any?(opts[:crontab], fn {_, worker} ->
             worker == Backplane.Memory.Workers.EvictionWorker
           end)

    assert Enum.any?(opts[:crontab], fn {_, worker} -> worker == StageResumeWorker end)
  end

  defp window_job!(session) do
    assert {:ok, enumeration} =
             WindowSummaryWorker.enqueue(
               session.host_id,
               session.session_id,
               session.input_revision,
               partition(session)
             )

    assert :ok = WindowSummaryWorker.perform(enumeration)

    Styx.Testing.all_enqueued(repo(), worker: WindowSummaryWorker)
    |> Enum.find(fn job ->
      job.args["mode"] == "window" and job.args["input_revision"] == session.input_revision
    end)
    |> then(fn job ->
      assert job
      job
    end)
  end

  defp window_state! do
    repo().one!(from(s in State, where: s.projector == "window_summary"))
  end

  defp session!(host, count, opts \\ []) do
    session = "session-#{host}"
    ingest_events!(host, session, Enum.to_list(1..count) -- Keyword.get(opts, :omit, []), count)
    assert {:ok, _} = Rebuild.session(host, session)
    repo().get!(ProjectedSession, Source.subject_id!(host, session))
  end

  defp ingest_events!(host, session, sequences, last) do
    sequences
    |> Enum.map(fn sequence ->
      type =
        cond do
          sequence == 1 -> "agent.session.started"
          sequence == last -> "agent.session.ended"
          true -> "agent.prompt.submitted"
        end

      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => host,
        "session_id" => session,
        "project" => "stage-project",
        "sequence" => sequence,
        "event_type" => type,
        "idempotency_key" => "#{host}:#{sequence}",
        "payload" => %{
          "message" =>
            if(sequence == 2,
              do: Enum.map_join(1..10, " ", &"Verified deployment action #{&1}."),
              else: "verified deployment step #{sequence}"
            )
        }
      })
    end)
    |> Enum.chunk_every(50)
    |> Enum.each(fn events ->
      assert {:ok, %{"results" => results}} =
               Ingest.ingest_batch(
                 ingest_auth_context(host, %{partition: %{scope: "project:backplane"}}),
                 %{"batch_id" => Ecto.UUID.generate(), "host_id" => host, "events" => events}
               )

      assert Enum.all?(results, &(&1["status"] == "accepted"))
    end)
  end

  defp partition(session),
    do:
      Map.take(
        Map.from_struct(session),
        [:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace]
      )

  defp state(session, projector),
    do:
      repo().one!(
        from(s in State,
          where: s.subject_id == ^session.subject_id and s.projector == ^projector
        )
      )
end
