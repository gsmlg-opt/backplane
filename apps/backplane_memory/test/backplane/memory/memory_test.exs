defmodule Backplane.Memory.MemoriesTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Memories

  defp partition(scope \\ "global") do
    %{host_id: "h", client_id: "client", scope: scope, namespace: "private"}
  end

  describe "remember/2" do
    test "stores a memory with defaults" do
      assert {:ok, mem} =
               Memories.remember("Paris is the capital of France.",
                 agent_id: "a",
                 host_id: "h",
                 client_id: "client"
               )

      assert mem.content == "Paris is the capital of France."
      assert mem.memory_type == "semantic"
      assert mem.scope == "global"
    end

    test "respects explicit type and scope options" do
      assert {:ok, mem} =
               Memories.remember("turn content",
                 type: "working",
                 scope: "proj-x",
                 agent_id: "a",
                 host_id: "h",
                 client_id: "client"
               )

      assert mem.memory_type == "working"
      assert mem.scope == "proj-x"
    end

    test "deduplicates identical content within same scope (returns existing id)" do
      opts = [agent_id: "a", host_id: "h", client_id: "client", scope: "proj-1"]
      {:ok, first} = Memories.remember("Unique fact.", opts)
      {:ok, second} = Memories.remember("Unique fact.", opts)
      assert first.id == second.id
    end

    test "does not deduplicate across different scopes" do
      {:ok, first} =
        Memories.remember("Fact.",
          agent_id: "a",
          host_id: "h",
          client_id: "client",
          scope: "scope-1"
        )

      {:ok, second} =
        Memories.remember("Fact.",
          agent_id: "a",
          host_id: "h",
          client_id: "client",
          scope: "scope-2"
        )

      assert first.id != second.id
    end

    test "does not deduplicate identical semantic content across hosts" do
      common = [
        agent_id: "agent",
        client_id: "shared-client",
        scope: "shared-scope",
        namespace: "private",
        type: "semantic"
      ]

      assert {:ok, first} = Memories.remember("host-specific fact", [host_id: "host-a"] ++ common)

      assert {:ok, second} =
               Memories.remember("host-specific fact", [host_id: "host-b"] ++ common)

      refute first.id == second.id
    end

    test "strips secrets via privacy filter before storing" do
      {:ok, mem} =
        Memories.remember("Key: sk-abcdef1234567890abcdef1234567890abcdef12",
          agent_id: "a",
          host_id: "h",
          client_id: "client"
        )

      refute mem.content =~ "sk-abcdef"
      assert mem.content =~ "[REDACTED]"
    end

    test "returns error when agent_id is missing" do
      assert {:error, _changeset} = Memories.remember("x", host_id: "h", client_id: "client")
    end
  end

  describe "get/1" do
    test "retrieves a non-deleted memory by id" do
      {:ok, mem} =
        Memories.remember("Berlin is in Germany.",
          agent_id: "a",
          host_id: "h",
          client_id: "client"
        )

      assert {:error, :unauthorized} = Memories.get(mem.id)
      assert {:ok, fetched} = Memories.get(mem.id, partition())
      assert fetched.id == mem.id
    end

    test "returns not_found for unknown id" do
      assert {:error, :unauthorized} = Memories.get(Ecto.UUID.generate())
      assert {:error, :not_found} = Memories.get(Ecto.UUID.generate(), partition())
    end
  end

  describe "forget/1" do
    test "tombstones a memory — get/1 returns not_found afterwards" do
      {:ok, mem} =
        Memories.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h", client_id: "client")

      assert {:error, :unauthorized} = Memories.forget(mem.id)
      assert :ok = Memories.forget(mem.id, partition())
      assert {:error, :not_found} = Memories.get(mem.id, partition())
    end

    test "returns not_found for unknown id" do
      assert {:error, :unauthorized} = Memories.forget(Ecto.UUID.generate())
      assert {:error, :not_found} = Memories.forget(Ecto.UUID.generate(), partition())
    end
  end

  describe "stats/0" do
    test "returns counts grouped by memory_type" do
      Memories.remember("s1", agent_id: "a", host_id: "h", client_id: "client", type: "semantic")
      Memories.remember("s2", agent_id: "a", host_id: "h", client_id: "client", type: "semantic")
      Memories.remember("w1", agent_id: "a", host_id: "h", client_id: "client", type: "working")
      stats = Memories.stats()
      assert %{memory_type: "semantic", count: 2} in stats
      assert %{memory_type: "working", count: 1} in stats
    end
  end

  describe "list/1 + count/1" do
    test "filters by type" do
      {:ok, _} =
        Memories.remember("a", agent_id: "a", host_id: "h", client_id: "client", type: "semantic")

      {:ok, _} =
        Memories.remember("b", agent_id: "a", host_id: "h", client_id: "client", type: "working")

      assert Memories.list(type: "semantic") == []
      assert [%{memory_type: "semantic"}] = Memories.list([type: "semantic"], partition())
      assert Memories.count(type: "semantic") == 0
      assert Memories.count([type: "semantic"], partition()) == 1
    end

    test "filters by scope and agent_id" do
      {:ok, _} =
        Memories.remember("a",
          agent_id: "agent-1",
          host_id: "h",
          client_id: "client",
          scope: "s1"
        )

      {:ok, _} =
        Memories.remember("b",
          agent_id: "agent-2",
          host_id: "h",
          client_id: "client",
          scope: "s2"
        )

      assert [%{scope: "s1"}] = Memories.list([scope: "s1"], partition("s1"))
      assert [%{agent_id: "agent-2"}] = Memories.list([agent_id: "agent-2"], partition("s2"))
    end

    test "ilike search on content" do
      {:ok, _} =
        Memories.remember("London is in the UK.",
          agent_id: "a",
          host_id: "h",
          client_id: "client"
        )

      {:ok, _} =
        Memories.remember("Madrid is in Spain.", agent_id: "a", host_id: "h", client_id: "client")

      results = Memories.list([q: "london"], partition())
      assert length(results) == 1
      assert hd(results).content =~ "London"
    end

    test "excludes soft-deleted by default" do
      {:ok, mem} =
        Memories.remember("to-be-forgotten", agent_id: "a", host_id: "h", client_id: "client")

      :ok = Memories.forget(mem.id, partition())
      assert Memories.list([], partition()) == []
      assert Memories.count([], partition()) == 0
    end

    test "include_deleted: true returns tombstoned rows" do
      {:ok, mem} =
        Memories.remember("soft-deleted", agent_id: "a", host_id: "h", client_id: "client")

      :ok = Memories.forget(mem.id, partition())
      assert [%{id: id}] = Memories.list([include_deleted: true], partition())
      assert id == mem.id
      assert Memories.count([include_deleted: true], partition()) == 1
    end

    test "pagination via limit + offset" do
      for i <- 1..3,
          do: Memories.remember("row #{i}", agent_id: "a", host_id: "h", client_id: "client")

      assert length(Memories.list([limit: 2, offset: 0], partition())) == 2
      assert length(Memories.list([limit: 2, offset: 2], partition())) == 1
    end

    test "list result does not include embedding column" do
      {:ok, _} = Memories.remember("x", agent_id: "a", host_id: "h", client_id: "client")
      [mem] = Memories.list([], partition())
      assert match?(%Ecto.Association.NotLoaded{}, mem.embedding) or is_nil(mem.embedding)
    end
  end

  describe "scope_stats/0" do
    test "returns counts grouped by scope (non-deleted)" do
      Memories.remember("a", agent_id: "a", host_id: "h", client_id: "client", scope: "alpha")
      Memories.remember("b", agent_id: "a", host_id: "h", client_id: "client", scope: "alpha")
      Memories.remember("c", agent_id: "a", host_id: "h", client_id: "client", scope: "beta")
      counts = Memories.scope_stats()
      assert %{scope: "alpha", count: 2} in counts
      assert %{scope: "beta", count: 1} in counts
    end
  end
end
