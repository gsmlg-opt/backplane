defmodule BackplaneMemory.Memories.MemoryTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memories.Memory

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "Paris is the capital of France.",
          agent_id: "a",
          host_id: "h"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :memory_type) == "semantic"
      assert Ecto.Changeset.get_field(cs, :scope) == "global"
    end

    test "content is required" do
      cs = Memory.changeset(%Memory{}, %{agent_id: "a", host_id: "h"})
      assert %{content: ["can't be blank"]} = errors_on(cs)
    end

    test "agent_id is required" do
      cs = Memory.changeset(%Memory{}, %{content: "x", host_id: "h"})
      assert %{agent_id: ["can't be blank"]} = errors_on(cs)
    end

    test "host_id is required" do
      cs = Memory.changeset(%Memory{}, %{content: "x", agent_id: "a"})
      assert %{host_id: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid memory_type is rejected" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "x",
          agent_id: "a",
          host_id: "h",
          memory_type: "invalid"
        })

      assert %{memory_type: ["is invalid"]} = errors_on(cs)
    end

    test "content_hash is derived from content" do
      cs = Memory.changeset(%Memory{}, %{content: "hello", agent_id: "a", host_id: "h"})
      assert Ecto.Changeset.get_change(cs, :content_hash) == :crypto.hash(:sha256, "hello")
    end
  end

  describe "Repo.insert/1" do
    test "inserts a valid memory row" do
      {:ok, mem} =
        %Memory{}
        |> Memory.changeset(%{
          content: "Rome is the capital of Italy.",
          agent_id: "a",
          host_id: "h"
        })
        |> Backplane.Repo.insert()

      assert mem.id != nil
      assert mem.memory_type == "semantic"
      assert mem.scope == "global"
      assert mem.content_hash == :crypto.hash(:sha256, "Rome is the capital of Italy.")
    end
  end
end
