defmodule Backplane.Memory.Workers.EpisodicWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Audit, Ingest, Memories}
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}

  defmodule MockLLM do
    def extract_facts(content) do
      send(self(), {:episodic_input, content})
      {:ok, Process.get(:episodic_facts, [])}
    end
  end

  setup do
    previous_llm = Application.get_env(:backplane_memory, :llm_module)
    setting = :ets.lookup(:backplane_settings, "memory.llm_model")

    Application.put_env(:backplane_memory, :llm_module, MockLLM)
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})

    on_exit(fn ->
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

  test "legacy session-only compatibility accepts exactly one validated key" do
    for args <- [
          %{},
          %{"session_id" => ""},
          %{"session_id" => "   "},
          %{"session_id" => 123},
          %{"session_id" => "legacy", "host_id" => "canonical-ish"},
          %{"session_id" => "legacy", "processing_version" => "summary-v1"}
        ] do
      assert {:cancel, :invalid_arguments} = EpisodicWorker.perform(%Oban.Job{args: args})
    end
  end

  defp insert_summary(session_id, project, content) do
    %Summary{}
    |> Summary.changeset(%{session_id: session_id, project: project, content: content})
    |> repo().insert!()
  end

  defp insert_canonical_summary(host_id, session_id, content) do
    revision = digest("#{host_id}:#{session_id}:#{content}")

    %Summary{}
    |> Summary.changeset(%{
      session_id: session_id,
      project: "project-canonical",
      content: content,
      subject_id: Backplane.Memory.Projections.Source.subject_id!(host_id, session_id),
      host_id: host_id,
      agent_id: "agent-canonical",
      processing_version: "summary-v1",
      input_revision: revision,
      output_revision: digest(content)
    })
    |> repo().insert!()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp perform(session_id),
    do: EpisodicWorker.perform(%Oban.Job{args: %{"session_id" => session_id}})

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
    %Oban.Job{
      args: %{
        "host_id" => host_id,
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
