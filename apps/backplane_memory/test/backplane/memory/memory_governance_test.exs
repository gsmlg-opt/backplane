defmodule Backplane.Memory.MemoryGovernanceTest do
  use Backplane.Memory.DataCase

  alias Backplane.Memory.{Audit, Memories}

  test "forget/1 writes an audit entry" do
    {:ok, mem} = Memories.remember("test governance", agent_id: "a1", host_id: "h1")
    :ok = Memories.forget(mem.id)

    entries = Audit.list(limit: 10)

    assert Enum.any?(entries, fn e ->
             e.operation in ["forget", "hard_delete"] and
               Enum.member?(Jason.decode!(Jason.encode!(e.target_ids)), mem.id)
           end)
  end
end
