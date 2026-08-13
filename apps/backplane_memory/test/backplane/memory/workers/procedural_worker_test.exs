defmodule Backplane.Memory.Workers.ProceduralWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.EvidenceInheritance
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Workers.ProceduralWorker

  defmodule MockLLM do
    def extract_procedures(content) do
      send(self(), {:procedural_input, content})
      {:ok, Process.get(:procedures, ["procedure"])}
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
             Memories.remember("bounded semantic",
               type: "semantic",
               scope: "bounded",
               agent_id: "agent",
               host_id: "host",
               evidence: evidence
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

  defp insert_partition(prefix, opts) do
    count = Keyword.get(opts, :count, 10)

    for ordinal <- 1..count do
      source_session_id = "#{prefix}-source-#{ordinal}"

      assert {:ok, _memory} =
               Memories.remember("#{prefix} semantic #{ordinal}",
                 type: "semantic",
                 scope: "shared-scope",
                 namespace: Keyword.fetch!(opts, :namespace),
                 client_id: Keyword.fetch!(opts, :client_id),
                 metadata: %{"project" => Keyword.fetch!(opts, :project)},
                 agent_id: "#{prefix}-agent",
                 host_id: "#{prefix}-host",
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
    end
  end

  defp insert_unqualified_decoys(prefix) do
    for ordinal <- 1..3 do
      assert {:ok, _memory} =
               Memories.remember("#{prefix} unqualified decoy #{ordinal}",
                 type: "semantic",
                 scope: "shared-scope",
                 namespace: "team:a",
                 client_id: "client-a",
                 metadata: %{"project" => "project-a"},
                 agent_id: "agent",
                 host_id: "host"
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
