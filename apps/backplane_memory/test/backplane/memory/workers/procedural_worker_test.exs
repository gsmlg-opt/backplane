defmodule Backplane.Memory.Workers.ProceduralWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.EvidenceInheritance
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedSession, State}
  alias Backplane.Memory.Workers.ProceduralWorker
  alias Backplane.MemorySpaces.BackfillIssue

  defmodule MockLLM do
    def extract_procedures(content) do
      send(self(), {:procedural_input, content})

      case Process.get(:procedural_result, {:ok, Process.get(:procedures, ["procedure"])}) do
        {:raise, message} -> raise message
        result -> result
      end
    end
  end

  defmodule BlockingLLM do
    def extract_procedures(_content) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:procedural_generation_blocked, self()})

      receive do
        :release_procedural_generation -> {:ok, ["stale procedure"]}
      end
    end
  end

  setup do
    previous_llm = Application.get_env(:backplane_memory, :llm_module)
    previous_client = Application.get_env(:backplane_memory, :llm_client)
    setting = :ets.lookup(:backplane_settings, "memory.llm_model")
    auto_extract = :ets.lookup(:backplane_settings, "memory.lesson_auto_extract")

    Application.put_env(:backplane_memory, :llm_module, MockLLM)
    Application.put_env(:backplane_memory, :llm_client, MockLLM)
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})
    :ets.insert(:backplane_settings, {"memory.lesson_auto_extract", true})

    on_exit(fn ->
      Process.delete(:procedural_result)
      :persistent_term.erase({BlockingLLM, :owner})
      restore_env(:llm_module, previous_llm)
      restore_env(:llm_client, previous_client)
      restore_setting("memory.llm_model", setting)
      restore_setting("memory.lesson_auto_extract", auto_extract)
    end)

    :ok
  end

  test "explicit typed lesson output with inherited evidence creates a consolidation candidate" do
    insert_partition("typed",
      namespace: "team:typed",
      client_id: "client-typed",
      project: "project-typed"
    )

    Process.put(:procedures, [
      %{
        "type" => "lesson",
        "rule" => "Always preserve the verified source chain",
        "context" => "consolidated evidence",
        "confidence" => 0.9
      }
    ])

    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    assert %Backplane.Memory.Lessons.Lesson{status: "candidate", source_kind: "consolidation"} =
             repo().one!(Backplane.Memory.Lessons.Lesson)
  end

  test "extracts within complete tenant partitions and inherits only root evidence" do
    insert_partition("alpha", namespace: "team:a", client_id: "client-a", project: "project-a")
    insert_partition("beta", namespace: "team:b", client_id: "client-b", project: "project-b")
    insert_unqualified_decoys("alpha")
    Process.put(:procedures, [" common procedure ", "common procedure"])

    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    inputs = receive_inputs(2)

    assert Enum.any?(
             inputs,
             &(String.contains?(&1, "alpha semantic") and
                 not String.contains?(&1, "beta semantic"))
           )

    assert Enum.any?(
             inputs,
             &(String.contains?(&1, "beta semantic") and
                 not String.contains?(&1, "alpha semantic"))
           )

    refute Enum.any?(inputs, &String.contains?(&1, "unqualified decoy"))

    procedures = repo().all(from(m in Memory, where: m.memory_type == "procedural"))
    assert length(procedures) == 2

    assert MapSet.new(
             Enum.map(procedures, &{&1.scope, &1.namespace, &1.client_id, &1.metadata["project"]})
           ) ==
             MapSet.new([
               {"shared-scope", "team:a", "client-a", "project-a"},
               {"shared-scope", "team:b", "client-b", "project-b"}
             ])

    for memory <- procedures do
      evidence = Memories.list_evidence(memory.id)
      assert Enum.count(evidence, &(&1.source_type == "request")) == 1
      assert Enum.count(evidence, &(&1.source_type == "session")) == 10

      assert Enum.all?(Enum.reject(evidence, &(&1.source_type == "request")), fn source ->
               source.evidence_kind == "derives" and source.support_score == 0.75 and
                 is_binary(source.excerpt)
             end)
    end
  end

  test "reordered retries are effect-free and changed output in a slot conflicts" do
    insert_partition("stable", namespace: "team:stable", client_id: "client", project: "project")
    Process.put(:procedures, [" z procedure ", "a procedure", "a procedure"])
    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    counts =
      {repo().aggregate(Memory, :count), repo().aggregate(RememberRequest, :count),
       repo().aggregate(Evidence, :count)}

    Process.put(:procedures, ["a procedure", "z procedure"])
    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    assert counts ==
             {repo().aggregate(Memory, :count), repo().aggregate(RememberRequest, :count),
              repo().aggregate(Evidence, :count)}

    Process.put(:procedures, ["changed", "z procedure"])
    assert {:error, :idempotency_conflict} = ProceduralWorker.perform(%Oban.Job{args: %{}})

    assert counts ==
             {repo().aggregate(Memory, :count), repo().aggregate(RememberRequest, :count),
              repo().aggregate(Evidence, :count)}
  end

  test "bounds inherited root evidence instead of silently truncating it" do
    for source <- ["source-one", "source-two"] do
      insert_source_session!("host", "host:host", "bounded", "private", source)
    end

    evidence =
      for source <- ["source-one", "source-two"] do
        %{
          source_session_id: source,
          session_id: source,
          host_id: "host",
          evidence_kind: "supports",
          support_score: 1.0
        }
      end

    assert {:ok, memory} =
             Memories.remember(
               "bounded semantic",
               canonical_memory_opts("host",
                 type: "semantic",
                 scope: "bounded",
                 agent_id: "agent",
                 evidence: evidence
               )
             )

    assert {:error, :evidence_limit_exceeded} =
             EvidenceInheritance.roots_by_memory([memory.id], limit: 1)
  end

  test "skips a partition with fewer than ten root-evidenced semantic inputs" do
    insert_partition("short",
      count: 9,
      namespace: "team:short",
      client_id: "client",
      project: "project"
    )

    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})
    refute_received {:procedural_input, _}
    assert repo().aggregate(from(m in Memory, where: m.memory_type == "procedural"), :count) == 0
  end

  test "skips a canonical-looking partition with an unresolved backfill issue" do
    [{:ok, memory} | _rest] =
      insert_partition("unresolved",
        namespace: "team:unresolved",
        client_id: "client",
        project: "project"
      )

    issue =
      repo().insert!(%BackfillIssue{
        source_table: "bpm_memories",
        source_id: memory.id,
        reason: "partition_mismatch",
        disposition: "pending",
        details: %{
          "memory_space_id" => memory.memory_space_id,
          "host_id" => memory.host_id,
          "scope" => memory.scope,
          "namespace" => memory.namespace
        }
      })

    for {field, wrong} <- [
          {"memory_space_id", canonical_partition("other-procedural").memory_space_id},
          {"host_id", "other-host"},
          {"client_id", "other-client"},
          {"scope", "other-scope"},
          {"namespace", "team:other"}
        ] do
      details = Map.put(issue.details, to_string(field), wrong)

      repo().update_all(from(i in BackfillIssue, where: i.id == ^issue.id),
        set: [details: details]
      )

      assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})
      refute_received {:procedural_input, _}
    end

    assert repo().aggregate(from(m in Memory, where: m.memory_type == "procedural"), :count) == 0
  end

  test "source validation durably quarantines every incomplete partition field" do
    partition = canonical_partition("procedural-boundary")

    for field <- [:memory_space_id, :host_id, :client_id, :scope, :namespace],
        invalid <- [nil, "", "   "] do
      id = Ecto.UUID.generate()
      source = partition |> Map.put(field, invalid) |> Map.put(:id, id)

      assert {:error, :incomplete_partition} =
               ProceduralWorker.validate_source_partition(source)

      assert %BackfillIssue{reason: "incomplete_partition", disposition: "pending"} =
               repo().get_by!(BackfillIssue, source_table: "bpm_memories", source_id: id)
    end
  end

  test "database constraints reject incomplete semantic generator inputs" do
    [{:ok, memory} | _rest] =
      insert_partition("incomplete",
        namespace: "team:incomplete",
        client_id: "client",
        project: "project"
      )

    assert_raise Postgrex.Error, fn ->
      repo().update_all(from(m in Memory, where: m.id == ^memory.id), set: [client_id: " "])
    end
  end

  test "records retryable failure before dead-lettering the final attempt" do
    [{:ok, memory} | _rest] =
      insert_partition("dead-letter",
        namespace: "team:dead-letter",
        client_id: "client-dead-letter",
        project: "project-dead-letter"
      )

    Process.put(:procedural_result, {:error, :llm_unavailable})

    assert {:error, :llm_unavailable} =
             ProceduralWorker.perform(%Oban.Job{args: %{}, attempt: 1, max_attempts: 2})

    assert %State{status: "failed", last_error: "llm_unavailable"} =
             repo().get_by!(State,
               projector: "procedural",
               memory_space_id: memory.memory_space_id,
               host_id: memory.host_id
             )

    assert {:error, :llm_unavailable} =
             ProceduralWorker.perform(%Oban.Job{args: %{}, attempt: 2, max_attempts: 2})

    assert %State{status: "dead_letter", last_error: "llm_unavailable"} =
             repo().get_by!(State,
               projector: "procedural",
               memory_space_id: memory.memory_space_id,
               host_id: memory.host_id
             )
  end

  test "records dead-letter before reraising an exception on the final attempt" do
    [{:ok, memory} | _rest] =
      insert_partition("exception",
        namespace: "team:exception",
        client_id: "client-exception",
        project: "project-exception"
      )

    Process.put(:procedural_result, {:raise, "procedural exploded"})

    assert_raise RuntimeError, "procedural exploded", fn ->
      ProceduralWorker.perform(%Oban.Job{args: %{}, attempt: 2, max_attempts: 2})
    end

    assert %State{status: "dead_letter", last_error: "procedural exploded"} =
             repo().get_by!(State,
               projector: "procedural",
               memory_space_id: memory.memory_space_id,
               host_id: memory.host_id
             )
  end

  test "a qualifying input committed during generation rejects all stale procedural writes" do
    [{:ok, first_memory} | _rest] =
      insert_partition("revision-race",
        namespace: "team:revision-race",
        client_id: "client-revision-race",
        project: "project-revision-race"
      )

    :persistent_term.put({BlockingLLM, :owner}, self())
    Application.put_env(:backplane_memory, :llm_module, BlockingLLM)

    old_task = Task.async(fn -> ProceduralWorker.perform(%Oban.Job{args: %{}}) end)
    Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), old_task.pid)
    old_task_pid = old_task.pid
    assert_receive {:procedural_generation_blocked, ^old_task_pid}, 5_000

    insert_source_session!(
      "revision-race-host",
      "client-revision-race",
      "shared-scope",
      "team:revision-race",
      "revision-race-source-r2"
    )

    assert {:ok, _new_input} =
             Memories.remember(
               "revision-race semantic R2",
               canonical_memory_opts("revision-race-host",
                 type: "semantic",
                 scope: "shared-scope",
                 namespace: "team:revision-race",
                 client_id: "client-revision-race",
                 metadata: %{"project" => "project-revision-race"},
                 agent_id: "revision-race-agent",
                 evidence: [
                   %{
                     source_session_id: "revision-race-source-r2",
                     session_id: "revision-race-source-r2",
                     agent_id: "source-agent",
                     host_id: "revision-race-host",
                     evidence_kind: "supports",
                     support_score: 0.75
                   }
                 ]
               )
             )

    Application.put_env(:backplane_memory, :llm_module, MockLLM)
    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    send(old_task.pid, :release_procedural_generation)
    assert :ok = Task.await(old_task, 5_000)

    refute repo().exists?(from(memory in Memory, where: memory.content == "stale procedure"))

    assert %State{status: "complete", input_revision: r2_revision} =
             repo().get_by!(State,
               projector: "procedural",
               memory_space_id: first_memory.memory_space_id,
               host_id: first_memory.host_id
             )

    refute is_nil(r2_revision)
  end

  defp insert_partition(prefix, opts) do
    count = Keyword.get(opts, :count, 10)

    for ordinal <- 1..count do
      source_session_id = "#{prefix}-source-#{ordinal}"

      insert_source_session!(
        "#{prefix}-host",
        Keyword.fetch!(opts, :client_id),
        "shared-scope",
        Keyword.fetch!(opts, :namespace),
        source_session_id
      )

      assert {:ok, _memory} =
               Memories.remember(
                 "#{prefix} semantic #{ordinal}",
                 canonical_memory_opts("#{prefix}-host",
                   type: "semantic",
                   scope: "shared-scope",
                   namespace: Keyword.fetch!(opts, :namespace),
                   client_id: Keyword.fetch!(opts, :client_id),
                   metadata: %{"project" => Keyword.fetch!(opts, :project)},
                   agent_id: "#{prefix}-agent",
                   evidence: [
                     %{
                       source_session_id: source_session_id,
                       session_id: source_session_id,
                       agent_id: "source-agent",
                       host_id: "#{prefix}-host",
                       evidence_kind: "supports",
                       support_score: 0.75,
                       excerpt: "#{prefix} excerpt #{ordinal}"
                     }
                   ]
                 )
               )
    end
  end

  defp insert_source_session!(host_id, client_id, scope, namespace, session_id) do
    repo().insert!(%ProjectedSession{
      subject_id: "procedural:#{session_id}",
      memory_space_id: Backplane.Memory.IngestFixtures.ensure_memory_space!(host_id),
      host_id: host_id,
      client_id: client_id,
      source_client_id: client_id,
      scope: scope,
      namespace: namespace,
      session_id: session_id,
      status: "completed",
      last_event_at: DateTime.utc_now(),
      processing_version: "session-v1",
      input_revision: "fixture-v1"
    })
  end

  defp insert_unqualified_decoys(prefix) do
    for ordinal <- 1..3 do
      assert {:ok, _memory} =
               Memories.remember(
                 "#{prefix} unqualified decoy #{ordinal}",
                 canonical_memory_opts("host",
                   type: "semantic",
                   scope: "shared-scope",
                   namespace: "team:a",
                   client_id: "client-a",
                   metadata: %{"project" => "project-a"},
                   agent_id: "agent"
                 )
               )
    end
  end

  defp receive_inputs(count) do
    for _ <- 1..count do
      assert_receive {:procedural_input, input}
      input
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp restore_setting(key, []), do: :ets.delete(:backplane_settings, key)
  defp restore_setting(_key, [entry]), do: :ets.insert(:backplane_settings, entry)
end
