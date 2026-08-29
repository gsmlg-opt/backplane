defmodule Backplane.Memory.Memories.MemoryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.Memory

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

  describe "Memories.tombstone/2" do
    test "soft-deletes only the exact partition and writes the ordinary forget audit" do
      previous = Backplane.Settings.get("memory.hard_delete_enabled")
      :ok = Backplane.Settings.set("memory.hard_delete_enabled", "false")
      on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

      partition = partition("host-a")

      {:ok, memory} =
        Memories.remember("host command memory", remember_options(partition))

      assert {:error, :not_found} = Memories.tombstone(memory.id, partition("host-b"))
      assert :ok = Memories.tombstone(memory.id, partition)

      assert %Memory{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
               Backplane.Repo.get!(Memory, memory.id)

      assert [%{operation: "forget", metadata: metadata}] =
               Audit.list_for_target(memory.id)
               |> Enum.filter(&(&1.operation == "forget"))

      assert metadata["from"] == "active"
      assert metadata["to"] == "tombstoned"
      assert metadata["result"] == "deleted"
      assert metadata["host_id"] == partition.host_id
      assert metadata["client_id"] == partition.client_id
      assert metadata["scope"] == partition.scope
      assert metadata["namespace"] == partition.namespace
    end

    test "stays soft when global hard delete is enabled" do
      previous = Backplane.Settings.get("memory.hard_delete_enabled")
      :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
      on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

      partition = partition("hard-delete-host")

      {:ok, memory} =
        Memories.remember("always soft host command", remember_options(partition))

      assert :ok = Memories.tombstone(memory.id, partition)

      assert %Memory{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
               Backplane.Repo.get!(Memory, memory.id)

      assert [%{operation: "forget"}] =
               Audit.list_for_target(memory.id)
               |> Enum.filter(&(&1.operation in ["forget", "hard_delete"]))
    end
  end

  defp partition(host_id) do
    %{
      host_id: host_id,
      client_id: "host:#{host_id}",
      scope: "scope:#{host_id}",
      namespace: "private"
    }
  end

  defp remember_options(partition) do
    [
      agent_id: "agent",
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace
    ]
  end
end
