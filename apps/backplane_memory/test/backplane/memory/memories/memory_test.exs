defmodule Backplane.Memory.Memories.MemoryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.Memory
  alias Backplane.MemorySpaces.MemorySpace

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "Paris is the capital of France.",
          agent_id: "a",
          host_id: "h",
          client_id: "client",
          scope: "global",
          namespace: "private",
          memory_space_id: Ecto.UUID.generate()
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :memory_type) == "semantic"
      assert Ecto.Changeset.get_field(cs, :scope) == "global"
    end

    test "content is required" do
      cs =
        Memory.changeset(%Memory{}, %{
          agent_id: "a",
          host_id: "h",
          memory_space_id: Ecto.UUID.generate()
        })

      assert %{content: ["can't be blank"]} = errors_on(cs)
    end

    test "agent_id is required" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "x",
          host_id: "h",
          memory_space_id: Ecto.UUID.generate()
        })

      assert %{agent_id: ["can't be blank"]} = errors_on(cs)
    end

    test "host_id is required" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "x",
          agent_id: "a",
          memory_space_id: Ecto.UUID.generate()
        })

      assert %{host_id: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid memory_type is rejected" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "x",
          agent_id: "a",
          host_id: "h",
          memory_space_id: Ecto.UUID.generate(),
          memory_type: "invalid"
        })

      assert %{memory_type: ["is invalid"]} = errors_on(cs)
    end

    test "content_hash is derived from content" do
      cs =
        Memory.changeset(%Memory{}, %{
          content: "hello",
          agent_id: "a",
          host_id: "h",
          memory_space_id: Ecto.UUID.generate()
        })

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
          host_id: "h",
          client_id: "client",
          scope: "global",
          namespace: "private",
          memory_space_id: insert_space!()
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
      assert metadata["memory_space_id"] == partition.memory_space_id
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
    memory_space_id = insert_space!()

    %{
      memory_space_id: memory_space_id,
      host_id: host_id,
      client_id: "host:#{host_id}",
      scope: "scope:#{host_id}",
      namespace: "private"
    }
  end

  defp remember_options(partition) do
    [
      agent_id: "agent",
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace
    ]
  end

  defp insert_space! do
    %MemorySpace{}
    |> MemorySpace.changeset(%{kind: "private", status: "active"})
    |> Backplane.Repo.insert!()
    |> Map.fetch!(:id)
  end

  describe "complete generator partitions" do
    alias Backplane.Memory.PartitionIdentity

    test "requires every authoritative and legacy owner field" do
      partition = canonical_partition("complete-owner")
      assert {:ok, validated} = PartitionIdentity.validate_generator(partition)
      assert validated.source_client_id == partition.source_client_id

      for field <- [:memory_space_id, :host_id, :client_id, :scope, :namespace],
          invalid <- [nil, "", "   "] do
        assert {:error, :incomplete_partition} =
                 partition |> Map.put(field, invalid) |> PartitionIdentity.validate_generator()
      end

      assert {:ok, without_source_client} =
               partition
               |> Map.delete(:source_client_id)
               |> PartitionIdentity.validate_generator()

      refute Map.has_key?(without_source_client, :source_client_id)
    end

    test "rejects every mismatched owner field" do
      expected = canonical_partition("expected-owner")

      for {field, mismatch} <- [
            memory_space_id: Ecto.UUID.generate(),
            host_id: "other-host",
            client_id: "other-client",
            scope: "other-scope",
            namespace: "other-namespace"
          ] do
        assert {:error, :partition_mismatch} =
                 expected
                 |> Map.put(field, mismatch)
                 |> PartitionIdentity.validate_generator(expected)
      end

      assert {:error, :partition_mismatch} =
               expected
               |> Map.put("host_id", "other-host")
               |> PartitionIdentity.validate_generator()
    end

    test "memory changesets reject blank complete-partition fields" do
      attrs =
        canonical_partition("changeset-owner")
        |> Map.merge(%{content: "complete memory", agent_id: "agent"})

      assert %Ecto.Changeset{valid?: true} = Memory.changeset(%Memory{}, attrs)

      for field <- [:host_id, :client_id, :scope, :namespace], invalid <- [nil, "", "   "] do
        changeset = Memory.changeset(%Memory{}, Map.put(attrs, field, invalid))
        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end

      changeset = Memory.changeset(%Memory{}, Map.put(attrs, :memory_space_id, nil))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).memory_space_id
    end
  end
end
