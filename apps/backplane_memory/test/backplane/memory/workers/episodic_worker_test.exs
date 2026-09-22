defmodule Backplane.Memory.Workers.EpisodicWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Audit, Ingest, Memories}
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedSession, Rebuild, Source, State}
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}
  alias Backplane.MemorySpaces.BackfillIssue

  defmodule MockLLM do
    def extract_facts(content) do
      send(self(), {:episodic_input, content})

      case Process.get(:episodic_result, {:ok, Process.get(:episodic_facts, [])}) do
        {:raise, message} -> raise message
        result -> result
      end
    end
  end

  defmodule BlockingLLM do
    @key {__MODULE__, :config}

    def configure(owner, blocked_content),
      do: :persistent_term.put(@key, %{owner: owner, blocked_content: blocked_content})

    def clear, do: :persistent_term.erase(@key)

    def extract_facts(content) do
      %{owner: owner, blocked_content: blocked_content} = :persistent_term.get(@key)

      if content == blocked_content do
        send(owner, {:episodic_llm_blocked, self(), content})

        receive do
          {:release_episodic_facts, facts} -> {:ok, facts}
        end
      else
        {:ok, []}
      end
    end
  end

  setup do
    previous_llm = Application.get_env(:backplane_memory, :llm_module)
    setting = :ets.lookup(:backplane_settings, "memory.llm_model")

    Application.put_env(:backplane_memory, :llm_module, MockLLM)
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})

    on_exit(fn ->
      Process.delete(:episodic_result)
      BlockingLLM.clear()
      restore_env(:llm_module, previous_llm)
      restore_setting("memory.llm_model", setting)
    end)

    :ok
  end

  test "normalizes facts and makes reordered retries effect-free" do
    summary = insert_summary("episodic-stable", "project-a", "summary revision")
    Process.put(:episodic_facts, [" z fact ", "a fact", "a fact", " "])

    assert :ok = perform(summary.session_id)
    assert_received {:episodic_input, "summary revision"}

    Process.put(:episodic_facts, ["z fact", "a fact"])
    assert :ok = perform(summary.session_id)

    assert ["a fact", "z fact"] ==
             Memory
             |> where([m], m.memory_type == "semantic" and m.scope == "project-a")
             |> order_by([m], asc: m.content)
             |> select([m], m.content)
             |> repo().all()

    assert repo().aggregate(RememberRequest, :count) == 2
    assert repo().aggregate(Evidence, :count) == 4

    for memory <- repo().all(from(m in Memory, where: m.memory_type == "semantic")) do
      assert ["request", "summary"] ==
               memory.id |> Memories.list_evidence() |> Enum.map(& &1.source_type)
    end
  end

  test "changed output in the same deterministic slot conflicts without new effects" do
    summary = insert_summary("episodic-conflict", "project-a", "fixed revision")
    Process.put(:episodic_facts, ["first fact"])
    assert :ok = perform(summary.session_id)

    Process.put(:episodic_facts, ["changed fact"])
    assert {:error, :idempotency_conflict} = perform(summary.session_id)

    assert repo().aggregate(Memory, :count) == 1
    assert repo().aggregate(RememberRequest, :count) == 1
    assert repo().aggregate(Evidence, :count) == 2

    assert %State{status: "failed", last_error: "idempotency_conflict"} =
             repo().get_by!(State, projector: "episodic", subject_id: summary.subject_id)
  end

  test "the same fact from independent summaries reuses the candidate and adds provenance" do
    first = insert_summary("episodic-one", "shared-project", "first source")
    second = insert_summary("episodic-two", "shared-project", "second source")
    Process.put(:episodic_facts, ["shared fact"])

    assert :ok = perform(first.session_id)
    assert :ok = perform(second.session_id)

    assert [memory] = repo().all(from(m in Memory, where: m.content == "shared fact"))

    summary_sources =
      memory.id
      |> Memories.list_evidence()
      |> Enum.filter(&(&1.source_type == "summary"))

    assert MapSet.new(Enum.map(summary_sources, & &1.source_id)) ==
             MapSet.new([first.id, second.id])

    assert Enum.map(summary_sources, & &1.session_id) |> Enum.sort() ==
             [first.session_id, second.session_id]
  end

  test "summary_id selects the exact canonical host/session evidence" do
    session_id = "shared-canonical-session"
    selected = insert_canonical_summary("host-selected", session_id, "selected source")
    _decoy = insert_canonical_summary("host-decoy", session_id, "decoy source")
    Process.put(:episodic_facts, ["selected fact"])

    assert :ok =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => selected.id}})

    assert_received {:episodic_input, "selected source"}
    refute_received {:episodic_input, "decoy source"}

    [memory] = repo().all(from(m in Memory, where: m.content == "selected fact"))
    evidence = Memories.list_evidence(memory.id)
    summary_evidence = Enum.find(evidence, &(&1.source_type == "summary"))
    assert summary_evidence.source_id == selected.id
    assert summary_evidence.host_id == "host-selected"
    assert summary_evidence.session_id == session_id
  end

  test "traces captured correlation through summary evidence into the automatic remember audit" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = "host-correlation"
      session_id = "session-correlation"
      correlation_id = Ecto.UUID.generate()

      auth =
        ingest_auth_context(host_id, %{
          auth_token_id: Ecto.UUID.generate(),
          partition: %{scope: "project:correlation"}
        })

      events =
        [
          capture_event(host_id, session_id, correlation_id, 1, "agent.session.started"),
          capture_event(host_id, session_id, correlation_id, 2, "agent.tool.completed"),
          capture_event(host_id, session_id, correlation_id, 3, "agent.session.ended")
        ]

      assert {:ok, %{"results" => results}} =
               Ingest.ingest_batch(auth, %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => host_id,
                 "events" => events
               })

      assert Enum.all?(results, &(&1["status"] == "accepted"))
      assert {:ok, projection} = Rebuild.session(host_id, session_id)

      assert :ok =
               SummaryWorker.perform(summary_job(host_id, session_id, projection.input_revision))

      summary =
        repo().one!(
          from(s in Summary,
            where: s.subject_id == ^projection.subject_id and s.processing_version == "summary-v1"
          )
        )

      Process.put(:episodic_facts, ["correlated automatic fact"])
      assert :ok = EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})

      assert [memory] =
               repo().all(from(m in Memory, where: m.content == "correlated automatic fact"))

      assert Enum.any?(Memories.list_evidence(memory.id), &(&1.source_id == summary.id))

      assert [%{metadata: metadata}] =
               Audit.list_for_target(memory.id)
               |> Enum.filter(&(&1.operation == "remember"))

      assert metadata["correlation_id"] == correlation_id
      assert metadata["correlation_ids"] == [correlation_id]
      assert {:ok, _request_id} = Ecto.UUID.cast(metadata["request_id"])
      assert metadata["host_id"] == host_id
      assert metadata["client_id"] == "host:#{host_id}"
      assert metadata["scope"] == "project:correlation"
      assert metadata["namespace"] == "private"
    end)
  end

  test "a discarded extraction can be re-enqueued and remains fact-idempotent" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      summary = insert_canonical_summary("host-heal", "session-heal", "healing source")
      Process.put(:episodic_facts, ["healed fact"])

      assert {:ok, discarded} = EpisodicWorker.enqueue_summary(summary.id)
      assert discarded.id

      repo().update_all(from(job in Oban.Job, where: job.id == ^discarded.id),
        set: [state: "discarded", discarded_at: DateTime.utc_now()]
      )

      assert {:ok, replacement} = EpisodicWorker.enqueue_summary(summary.id)
      refute replacement.id == discarded.id

      job = %Oban.Job{args: %{"summary_id" => summary.id}}
      assert :ok = EpisodicWorker.perform(job)
      assert :ok = EpisodicWorker.perform(job)
      assert repo().aggregate(from(m in Memory, where: m.content == "healed fact"), :count) == 1
      assert repo().aggregate(RememberRequest, :count) == 1
    end)
  end

  test "legacy session-only jobs fail closed without an owner partition" do
    for args <- [
          %{},
          %{"session_id" => 123},
          %{"session_id" => "legacy", "host_id" => "canonical-ish"},
          %{"session_id" => "legacy", "processing_version" => "summary-v1"}
        ] do
      assert {:cancel, :invalid_arguments} = EpisodicWorker.perform(%Oban.Job{args: args})
    end

    assert {:cancel, :incomplete_partition} =
             EpisodicWorker.perform(%Oban.Job{args: %{"session_id" => "legacy"}})
  end

  test "incomplete or mismatched summary ownership is durably quarantined" do
    incomplete = insert_canonical_summary("episodic-incomplete", "session", "content")

    repo().update_all(
      from(s in ProjectedSession, where: s.subject_id == ^incomplete.subject_id),
      set: [client_id: " "]
    )

    assert {:discard, :incomplete_partition} =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => incomplete.id}})

    assert %BackfillIssue{reason: "incomplete_partition", disposition: "pending"} =
             repo().get_by!(BackfillIssue,
               source_table: "memory_summaries",
               source_id: incomplete.id
             )

    mismatched = insert_canonical_summary("episodic-mismatch", "session", "content")

    repo().update_all(from(s in Summary, where: s.id == ^mismatched.id),
      set: [host_id: "other-host"]
    )

    assert {:discard, :partition_mismatch} =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => mismatched.id}})

    assert %BackfillIssue{reason: "partition_mismatch", disposition: "pending"} =
             repo().get_by!(BackfillIssue,
               source_table: "memory_summaries",
               source_id: mismatched.id
             )
  end

  test "partition resolution quarantines every incomplete source field and summary mismatch" do
    partition = canonical_partition("episodic-boundary")

    summary = %Summary{
      id: Ecto.UUID.generate(),
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      source_client_id: nil,
      scope: partition.scope,
      namespace: partition.namespace
    }

    for field <- [:memory_space_id, :host_id, :client_id, :scope, :namespace],
        invalid <- [nil, "", "   "] do
      assert {:error, :incomplete_partition} =
               EpisodicWorker.resolve_partition(summary, Map.put(partition, field, invalid))

      assert %BackfillIssue{reason: "incomplete_partition", disposition: "pending"} =
               repo().get_by!(BackfillIssue,
                 source_table: "memory_summaries",
                 source_id: summary.id
               )
    end

    for {field, wrong} <- [
          memory_space_id: canonical_partition("episodic-other").memory_space_id,
          host_id: "other-host",
          scope: "other-scope",
          namespace: "team:other"
        ] do
      assert {:error, :partition_mismatch} =
               summary
               |> Map.put(field, wrong)
               |> EpisodicWorker.resolve_partition(partition)

      assert %BackfillIssue{reason: "partition_mismatch", disposition: "pending"} =
               repo().get_by!(BackfillIssue,
                 source_table: "memory_summaries",
                 source_id: summary.id
               )
    end
  end

  test "validates and quarantines ownership before the no-model early return" do
    summary = insert_canonical_summary("episodic-no-model", "session", "content")

    repo().update_all(
      from(s in ProjectedSession, where: s.subject_id == ^summary.subject_id),
      set: [client_id: " "]
    )

    :ets.delete(:backplane_settings, "memory.llm_model")

    assert {:discard, :incomplete_partition} =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})

    assert %BackfillIssue{reason: "incomplete_partition"} =
             repo().get_by!(BackfillIssue,
               source_table: "memory_summaries",
               source_id: summary.id
             )
  end

  test "records a no-model terminal processing state" do
    summary = insert_canonical_summary("episodic-state", "session", "content")
    :ets.delete(:backplane_settings, "memory.llm_model")

    assert :ok = EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})

    assert %State{status: "skipped_no_model", last_error: "no_model"} =
             repo().get_by!(State,
               projector: "episodic",
               subject_type: "captured_session",
               subject_id: summary.subject_id
             )
  end

  test "records retryable failure before dead-lettering the final attempt" do
    summary = insert_canonical_summary("episodic-dead-letter", "session", "content")
    Process.put(:episodic_result, {:error, :llm_unavailable})

    assert {:error, :llm_unavailable} =
             EpisodicWorker.perform(%Oban.Job{
               args: %{"summary_id" => summary.id},
               attempt: 1,
               max_attempts: 3
             })

    assert %State{status: "failed", last_error: "llm_unavailable"} =
             repo().get_by!(State, projector: "episodic", subject_id: summary.subject_id)

    assert {:error, :llm_unavailable} =
             EpisodicWorker.perform(%Oban.Job{
               args: %{"summary_id" => summary.id},
               attempt: 3,
               max_attempts: 3
             })

    assert %State{status: "dead_letter", last_error: "llm_unavailable"} =
             repo().get_by!(State, projector: "episodic", subject_id: summary.subject_id)
  end

  test "a stale summary revision cannot replace the current processing state" do
    summary = insert_canonical_summary("episodic-stale", "session", "content")

    repo().update_all(
      from(session in ProjectedSession, where: session.subject_id == ^summary.subject_id),
      set: [input_revision: digest("newer revision")]
    )

    assert {:discard, :stale_input_revision} =
             EpisodicWorker.perform(%Oban.Job{
               args: %{"summary_id" => summary.id},
               attempt: 3,
               max_attempts: 3
             })

    refute repo().get_by(State, projector: "episodic", subject_id: summary.subject_id)
  end

  test "a concurrent projected revision advance wins before an old job claims running" do
    summary = insert_canonical_summary("episodic-claim-race", "session", "old content")
    newer_revision = digest("newer concurrent revision")
    parent = self()

    advance_task =
      Task.async(fn ->
        repo().transaction(fn ->
          session =
            repo().one!(
              from(projected in ProjectedSession,
                where: projected.subject_id == ^summary.subject_id,
                lock: "FOR UPDATE"
              )
            )

          repo().update_all(
            from(projected in ProjectedSession,
              where: projected.subject_id == ^session.subject_id
            ),
            set: [input_revision: newer_revision]
          )

          send(parent, :revision_advanced)

          receive do
            :commit_revision -> :ok
          end
        end)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), advance_task.pid)
    assert_receive :revision_advanced, 5_000

    worker_task =
      Task.async(fn ->
        EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})
      end)

    Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), worker_task.pid)
    assert Task.yield(worker_task, 100) == nil

    send(advance_task.pid, :commit_revision)
    assert {:ok, :ok} = Task.await(advance_task, 5_000)
    assert {:discard, :stale_input_revision} = Task.await(worker_task, 5_000)
    refute_received {:episodic_input, _content}
    refute repo().get_by(State, projector: "episodic", subject_id: summary.subject_id)
  end

  test "a revision advancing during extraction cannot persist stale semantic facts" do
    old = insert_canonical_summary("episodic-persist-race", "session", "old content")
    BlockingLLM.configure(self(), old.content)
    Application.put_env(:backplane_memory, :llm_module, BlockingLLM)

    old_task =
      Task.async(fn ->
        EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => old.id}})
      end)

    Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), old_task.pid)
    assert_receive {:episodic_llm_blocked, old_task_pid, "old content"}, 5_000
    assert old_task_pid == old_task.pid

    newer = replace_canonical_summary(old, "new content")

    new_task =
      Task.async(fn ->
        EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => newer.id}})
      end)

    Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), new_task.pid)
    assert :ok = Task.await(new_task, 5_000)

    assert %State{status: "complete", input_revision: newer_revision} =
             repo().get_by!(State, projector: "episodic", subject_id: newer.subject_id)

    assert newer_revision == newer.input_revision

    send(old_task.pid, {:release_episodic_facts, ["stale semantic fact"]})
    assert {:discard, :stale_input_revision} = Task.await(old_task, 5_000)

    assert %State{status: "complete", input_revision: ^newer_revision} =
             repo().get_by!(State, projector: "episodic", subject_id: newer.subject_id)

    assert repo().aggregate(from(m in Memory, where: m.memory_type == "semantic"), :count) == 0
    assert repo().aggregate(RememberRequest, :count) == 0
    assert repo().aggregate(Evidence, :count) == 0
  end

  test "old and new summary jobs executed out of order retain the newer durable revision" do
    old = insert_canonical_summary("episodic-out-of-order", "session", "old content")
    new = replace_canonical_summary(old, "new content")
    Process.put(:episodic_facts, [])

    assert :ok = EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => new.id}})

    assert %State{status: "complete", input_revision: revision} =
             repo().get_by!(State, projector: "episodic", subject_id: new.subject_id)

    assert revision == new.input_revision

    assert {:discard, :stale_input_revision} =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => old.id}})

    assert %State{status: "complete", input_revision: ^revision} =
             repo().get_by!(State, projector: "episodic", subject_id: new.subject_id)
  end

  test "an exception on the final attempt records dead-letter before reraising" do
    summary = insert_canonical_summary("episodic-exception", "session", "content")
    Process.put(:episodic_result, {:raise, "episodic exploded"})

    assert_raise RuntimeError, "episodic exploded", fn ->
      EpisodicWorker.perform(%Oban.Job{
        args: %{"summary_id" => summary.id},
        attempt: 3,
        max_attempts: 3
      })
    end

    assert %State{status: "dead_letter", last_error: "episodic exploded"} =
             repo().get_by!(State, projector: "episodic", subject_id: summary.subject_id)
  end

  test "missing projected session is durably quarantined" do
    summary = insert_canonical_summary("episodic-no-session", "session", "content")
    repo().delete_all(from(s in ProjectedSession, where: s.subject_id == ^summary.subject_id))

    assert {:discard, :incomplete_partition} =
             EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})

    assert %BackfillIssue{reason: "incomplete_partition"} =
             repo().get_by!(BackfillIssue,
               source_table: "memory_summaries",
               source_id: summary.id
             )
  end

  defp insert_summary(session_id, project, content) do
    partition = canonical_partition("legacy", scope: project)

    summary =
      %Summary{}
      |> Summary.changeset(
        partition
        |> Map.merge(%{session_id: session_id, project: project, content: content})
      )
      |> repo().insert!()

    insert_projected_session!(summary, partition)
    summary
  end

  defp insert_canonical_summary(host_id, session_id, content) do
    revision = digest("#{host_id}:#{session_id}:#{content}")
    partition = canonical_partition(host_id, scope: "project-canonical")

    summary =
      %Summary{}
      |> Summary.changeset(
        partition
        |> Map.merge(%{
          session_id: session_id,
          project: "project-canonical",
          content: content,
          subject_id: Source.subject_id!(host_id, session_id),
          agent_id: "agent-canonical",
          processing_version: "summary-v1",
          input_revision: revision,
          output_revision: digest(content)
        })
      )
      |> repo().insert!()

    insert_projected_session!(summary, partition)
    summary
  end

  defp insert_projected_session!(summary, partition) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo().insert!(%ProjectedSession{
      subject_id: summary.subject_id,
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      client_id: partition.client_id,
      source_client_id: partition.source_client_id,
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: summary.session_id,
      project: summary.project,
      agent_id: summary.agent_id,
      status: "completed",
      started_at: now,
      ended_at: now,
      last_event_at: now,
      source_sequence_max: 1,
      gap_count: 0,
      processing_version: "session-v1",
      input_revision: summary.input_revision
    })
  end

  defp replace_canonical_summary(old, content) do
    revision = digest("#{old.host_id}:#{old.session_id}:#{content}")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old
    |> Summary.changeset(%{
      processing_version: "summary-v1@#{old.input_revision}",
      superseded_at: now,
      superseded_by_input_revision: revision
    })
    |> repo().update!()

    repo().update_all(
      from(session in ProjectedSession, where: session.subject_id == ^old.subject_id),
      set: [input_revision: revision]
    )

    %Summary{}
    |> Summary.changeset(%{
      memory_space_id: old.memory_space_id,
      host_id: old.host_id,
      source_client_id: old.source_client_id,
      scope: old.scope,
      namespace: old.namespace,
      session_id: old.session_id,
      project: old.project,
      content: content,
      subject_id: old.subject_id,
      agent_id: old.agent_id,
      processing_version: "summary-v1",
      input_revision: revision,
      output_revision: digest(content)
    })
    |> repo().insert!()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp perform(session_id),
    do:
      EpisodicWorker.perform(%Oban.Job{
        args: %{"summary_id" => repo().get_by!(Summary, session_id: session_id).id}
      })

  defp capture_event(host_id, session_id, correlation_id, sequence, event_type) do
    payload = %{"message" => "correlation source #{sequence}"}

    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "client_id" => "capture-client",
      "scope" => "project:correlation",
      "project" => "correlation",
      "session_id" => session_id,
      "sequence" => sequence,
      "event_type" => event_type,
      "idempotency_key" => "correlation:#{session_id}:#{sequence}",
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "captured_at" => "2026-08-04T01:0#{sequence}:00.010Z",
      "trace" => %{"correlation_id" => correlation_id},
      "payload" => payload,
      "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
    })
  end

  defp summary_job(host_id, session_id, input_revision) do
    session = repo().get!(ProjectedSession, Source.subject_id!(host_id, session_id))

    %Oban.Job{
      args: %{
        "memory_space_id" => session.memory_space_id,
        "host_id" => host_id,
        "client_id" => session.client_id,
        "source_client_id" => session.source_client_id,
        "scope" => session.scope,
        "namespace" => session.namespace,
        "session_id" => session_id,
        "processing_version" => "summary-v1",
        "input_revision" => input_revision
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp restore_setting(key, []), do: :ets.delete(:backplane_settings, key)
  defp restore_setting(_key, [entry]), do: :ets.insert(:backplane_settings, entry)
end
