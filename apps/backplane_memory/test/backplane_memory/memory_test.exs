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

  describe "list/1 + count/1" do
    test "filters by type" do
      {:ok, _} = Memory.remember("a", agent_id: "a", host_id: "h", type: "semantic")
      {:ok, _} = Memory.remember("b", agent_id: "a", host_id: "h", type: "working")

      assert [%{memory_type: "semantic"}] = Memory.list(type: "semantic")
      assert Memory.count(type: "semantic") == 1
    end

    test "filters by scope and agent_id" do
      {:ok, _} = Memory.remember("a", agent_id: "agent-1", host_id: "h", scope: "s1")
      {:ok, _} = Memory.remember("b", agent_id: "agent-2", host_id: "h", scope: "s2")

      assert [%{scope: "s1"}] = Memory.list(scope: "s1")
      assert [%{agent_id: "agent-2"}] = Memory.list(agent_id: "agent-2")
    end

    test "ilike search on content" do
      {:ok, _} = Memory.remember("London is in the UK.", agent_id: "a", host_id: "h")
      {:ok, _} = Memory.remember("Madrid is in Spain.", agent_id: "a", host_id: "h")

      results = Memory.list(q: "london")
      assert length(results) == 1
      assert hd(results).content =~ "London"
    end

    test "excludes soft-deleted by default" do
      {:ok, mem} = Memory.remember("to-be-forgotten", agent_id: "a", host_id: "h")
      :ok = Memory.forget(mem.id)
      assert Memory.list() == []
      assert Memory.count() == 0
    end

    test "include_deleted: true returns tombstoned rows" do
      {:ok, mem} = Memory.remember("soft-deleted", agent_id: "a", host_id: "h")
      :ok = Memory.forget(mem.id)
      assert [%{id: id}] = Memory.list(include_deleted: true)
      assert id == mem.id
      assert Memory.count(include_deleted: true) == 1
    end

    test "pagination via limit + offset" do
      for i <- 1..3, do: Memory.remember("row #{i}", agent_id: "a", host_id: "h")
      assert length(Memory.list(limit: 2, offset: 0)) == 2
      assert length(Memory.list(limit: 2, offset: 2)) == 1
    end

    test "list result does not include embedding column" do
      {:ok, _} = Memory.remember("x", agent_id: "a", host_id: "h")
      [mem] = Memory.list()
      assert match?(%Ecto.Association.NotLoaded{}, mem.embedding) or is_nil(mem.embedding)
    end
  end

  describe "scope_stats/0" do
    test "returns counts grouped by scope (non-deleted)" do
      Memory.remember("a", agent_id: "a", host_id: "h", scope: "alpha")
      Memory.remember("b", agent_id: "a", host_id: "h", scope: "alpha")
      Memory.remember("c", agent_id: "a", host_id: "h", scope: "beta")
      counts = Memory.scope_stats()
      assert %{scope: "alpha", count: 2} in counts
      assert %{scope: "beta", count: 1} in counts
    end
  end
end
