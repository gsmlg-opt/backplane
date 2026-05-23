defmodule BackplaneMemory.MemoryTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memory

  describe "remember/2" do
    test "stores a memory with defaults" do
      assert {:ok, mem} =
               Memory.remember("Paris is the capital of France.", agent_id: "a", host_id: "h")

      assert mem.content == "Paris is the capital of France."
      assert mem.memory_type == "semantic"
      assert mem.scope == "global"
    end

    test "respects explicit type and scope options" do
      assert {:ok, mem} =
               Memory.remember("turn content",
                 type: "working",
                 scope: "proj-x",
                 agent_id: "a",
                 host_id: "h"
               )

      assert mem.memory_type == "working"
      assert mem.scope == "proj-x"
    end

    test "deduplicates identical content within same scope (returns existing id)" do
      opts = [agent_id: "a", host_id: "h", scope: "proj-1"]
      {:ok, first} = Memory.remember("Unique fact.", opts)
      {:ok, second} = Memory.remember("Unique fact.", opts)
      assert first.id == second.id
    end

    test "does not deduplicate across different scopes" do
      {:ok, first} = Memory.remember("Fact.", agent_id: "a", host_id: "h", scope: "scope-1")
      {:ok, second} = Memory.remember("Fact.", agent_id: "a", host_id: "h", scope: "scope-2")
      assert first.id != second.id
    end

    test "strips secrets via privacy filter before storing" do
      {:ok, mem} =
        Memory.remember("Key: sk-abcdef1234567890abcdef1234567890abcdef12",
          agent_id: "a",
          host_id: "h"
        )

      refute mem.content =~ "sk-abcdef"
      assert mem.content =~ "[REDACTED]"
    end

    test "returns error when agent_id is missing" do
      assert {:error, _changeset} = Memory.remember("x", host_id: "h")
    end
  end

  describe "get/1" do
    test "retrieves a non-deleted memory by id" do
      {:ok, mem} = Memory.remember("Berlin is in Germany.", agent_id: "a", host_id: "h")
      assert {:ok, fetched} = Memory.get(mem.id)
      assert fetched.id == mem.id
    end

    test "returns not_found for unknown id" do
      assert {:error, :not_found} = Memory.get(Ecto.UUID.generate())
    end
  end

  describe "forget/1" do
    test "tombstones a memory — get/1 returns not_found afterwards" do
      {:ok, mem} = Memory.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h")
      assert :ok = Memory.forget(mem.id)
      assert {:error, :not_found} = Memory.get(mem.id)
    end

    test "returns not_found for unknown id" do
      assert {:error, :not_found} = Memory.forget(Ecto.UUID.generate())
    end
  end

  describe "stats/0" do
    test "returns counts grouped by memory_type" do
      Memory.remember("s1", agent_id: "a", host_id: "h", type: "semantic")
      Memory.remember("s2", agent_id: "a", host_id: "h", type: "semantic")
      Memory.remember("w1", agent_id: "a", host_id: "h", type: "working")
      stats = Memory.stats()
      assert %{memory_type: "semantic", count: 2} in stats
      assert %{memory_type: "working", count: 1} in stats
    end
  end
end
