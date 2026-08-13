defmodule Backplane.Memory.ApplicationCountTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.Search

  test "only an explicit successful procedural application increments and audits" do
    partition = partition("host-a")

    assert {:ok, procedural} =
             Memories.remember("Apply this procedure",
               type: "procedural",
               agent_id: "author",
               host_id: partition.host_id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace
             )

    assert {:ok, semantic} =
             Memories.remember("A factual memory",
               type: "semantic",
               agent_id: "author",
               host_id: partition.host_id,
               client_id: partition.client_id,
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
               host_id: partition.host_id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace
             )

    assert {:ok, [%{id: procedure_id}]} =
             Search.hybrid_recall("verify exact served artifact",
               host_id: partition.host_id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               writeback_fn: fn _ids -> :ok end,
               embed_fn: fn _texts, _mode, _opts -> {:error, :not_configured} end
             )

    assert procedure_id == procedure.id
    assert {:ok, verification} = Memories.verify(procedure.id, partition)
    assert verification.application_count == 0
  end

  defp partition(host_id) do
    %{host_id: host_id, client_id: "shared-client", scope: "shared-scope", namespace: "private"}
  end
end
