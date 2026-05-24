defmodule BackplaneMemory.MemoryGovernanceTest do
  use BackplaneMemory.DataCase

  alias BackplaneMemory.{Memory, Audit}

  test "forget/1 writes an audit entry" do
    {:ok, mem} = Memory.remember("test governance", agent_id: "a1", host_id: "h1")
    :ok = Memory.forget(mem.id)

    entries = Audit.list(limit: 10)

    assert Enum.any?(entries, fn e ->
             e.operation in ["forget", "hard_delete"] and
               Enum.member?(Jason.decode!(Jason.encode!(e.target_ids)), mem.id)
           end)
  end
end
