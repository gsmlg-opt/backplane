defmodule Backplane.Memory.MemoryGovernanceTest do
  use Backplane.Memory.DataCase

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}

  test "legacy contradiction heuristic is an unconditional no-op" do
    {:ok, first} = Memories.remember("same tags one", agent_id: "a", host_id: "h", tags: ["x"])
    {:ok, second} = Memories.remember("same tags two", agent_id: "a", host_id: "h", tags: ["x"])

    assert {:ok, :no_change} = Memories.maybe_detect_contradiction(first.id, second.id)
    assert Memories.get(first.id) == {:error, :unauthorized}
    assert Memories.trusted_get(first.id) == {:ok, first}
    assert Memories.trusted_get(second.id) == {:ok, second}
  end

  test "forget/1 writes an audit entry" do
    {:ok, mem} = Memories.remember("test governance", agent_id: "a1", host_id: "h1")
    assert {:error, :unauthorized} = Memories.forget(mem.id)
    :ok = Memories.trusted_forget(mem.id)

    entries = Audit.list(limit: 10)

    assert Enum.any?(entries, fn e ->
             e.operation in ["forget", "hard_delete"] and
               Enum.member?(Jason.decode!(Jason.encode!(e.target_ids)), mem.id)
           end)
  end

  test "target audit lookup handles legacy arrays and maps without a global prelimit" do
    {:ok, mem} = Memories.remember("targeted audit", agent_id: "a1", host_id: "h1")
    :ok = Audit.log("legacy_array", "system", [mem.id], %{"shape" => "array"})
    :ok = Audit.log("legacy_map", "system", %{"memory_id" => mem.id}, %{"shape" => "map"})

    for n <- 1..501 do
      :ok = Audit.log("unrelated", "system", [Ecto.UUID.generate()], %{"n" => n})
    end

    entries = Audit.list_for_target(mem.id)
    assert Enum.map(entries, & &1.operation) == ["legacy_map", "legacy_array", "remember"]

    assert {:error, :unauthorized} = Memories.verify(mem.id)
    assert {:ok, verification} = Memories.trusted_verify(mem.id)

    assert Enum.map(verification.audit, & &1.operation) == [
             "legacy_map",
             "legacy_array",
             "remember"
           ]
  end

  test "hard delete refuses retained provenance and audits the exact denied attempt" do
    previous = Backplane.Settings.get("memory.hard_delete_enabled")
    :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
    on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

    {:ok, mem} = Memories.remember("retained provenance", agent_id: "a1", host_id: "h1")

    assert {:error, :unauthorized} = Memories.forget(mem.id)
    assert {:error, :provenance_retained} = Memories.trusted_forget(mem.id)
    assert {:ok, ^mem} = Memories.trusted_get(mem.id)
    assert repo().aggregate(Evidence, :count) == 1
    assert repo().aggregate(RememberRequest, :count) == 1

    assert [%{operation: "hard_delete", target_ids: [memory_id], metadata: metadata}] =
             Audit.list_for_target(mem.id)
             |> Enum.filter(&(&1.operation == "hard_delete"))

    assert memory_id == mem.id
    assert metadata["result"] == "denied"
    assert metadata["reason"] == "provenance_retained"
    assert metadata["host_id"] == mem.host_id
    assert metadata["client_id"] == mem.client_id
    assert metadata["scope"] == mem.scope
    assert metadata["namespace"] == mem.namespace
    assert {:ok, _request_id} = Ecto.UUID.cast(metadata["request_id"])
    refute Map.has_key?(metadata, "content")
    refute Map.has_key?(metadata, "raw")
  end

  test "hard delete defensively refuses a legacy inbound superseded_by reference" do
    previous = Backplane.Settings.get("memory.hard_delete_enabled")
    :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
    on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

    target = insert_legacy_memory!("legacy target")
    predecessor = insert_legacy_memory!("legacy predecessor")

    predecessor
    |> Memory.lifecycle_changeset(%{
      lifecycle_state: "superseded",
      superseded_by: target.id
    })
    |> repo().update!()

    assert {:error, :provenance_retained} = Memories.trusted_forget(target.id)
    assert {:ok, %{id: target_id}} = Memories.trusted_get(target.id)
    assert target_id == target.id
  end

  defp insert_legacy_memory!(content) do
    %Memory{}
    |> Memory.changeset(%{content: content, agent_id: "legacy", host_id: "legacy"})
    |> repo().insert!()
  end
end
