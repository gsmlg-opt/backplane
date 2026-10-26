defmodule Backplane.Memory.ApplicationCountTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Recall.Pipeline

  setup do
    previous = Application.get_env(:backplane_memory, :recall_task_supervisor)
    supervisor = start_supervised!(Task.Supervisor)
    Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :recall_task_supervisor, previous),
        else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
    end)

    :ok
  end

  test "only an explicit successful procedural application increments and audits" do
    partition = partition("host-a")

    assert {:ok, procedural} =
             Memories.remember("Apply this procedure",
               type: "procedural",
               agent_id: "author",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace
             )

    assert {:ok, semantic} =
             Memories.remember("A factual memory",
               type: "semantic",
               agent_id: "author",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace
             )

    assert {:error, :not_applicable} =
             Memories.record_application(semantic.id, "attempt-1", "executor", partition)

    assert {:error, :not_found} =
             Memories.record_application(
               procedural.id,
               "attempt-2",
               "executor",
               partition("host-b")
             )

    assert {:ok, %{application_count: 1, applied: true}} =
             Memories.record_application(procedural.id, "attempt-3", "executor", partition)

    assert {:ok, %{application_count: 1, applied: false}} =
             Memories.record_application(procedural.id, "attempt-3", "executor", partition)

    assert {:ok, verification} = Memories.verify(procedural.id, partition)
    assert verification.application_count == 1

    assert [%{actor: "executor", metadata: metadata}] =
             Audit.list_for_target(procedural.id)
             |> Enum.filter(&(&1.operation == "memory.apply"))

    assert metadata["application_id"] == "attempt-3"
    assert metadata["result"] == "succeeded"
    assert metadata["application_count"] == 1
    refute Map.has_key?(metadata, "content")
    refute Map.has_key?(metadata, "raw")
  end

  test "recall access does not increment application count" do
    partition = partition("recall-host")

    assert {:ok, procedure} =
             Memories.remember("Always verify the exact served artifact",
               type: "procedural",
               agent_id: "author",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace
             )

    assert {:ok, %{results: [%{id: procedure_id}]}} =
             Pipeline.run(
               Map.merge(partition, %{
                 query: "verify exact served artifact",
                 channel_weights: %{fts: 1.0, vector: 0.0, graph: 0.0}
               }),
               trace?: false,
               reranker_opts: [enabled: false]
             )

    assert procedure_id == procedure.id
    assert {:ok, verification} = Memories.verify(procedure.id, partition)
    assert verification.application_count == 0
  end

  defp partition(host_id) do
    canonical_partition(host_id,
      client_id: "shared-client",
      source_client_id: "shared-client",
      scope: "shared-scope"
    )
  end
end
