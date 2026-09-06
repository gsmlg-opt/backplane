defmodule Backplane.Memory.PartitionTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Partition
  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.BackfillIssue

  test "resolves authenticated legacy host identity to the stable canonical owner" do
    host_id = insert_host("partition-resolver", "scope:alpha")
    assert {:ok, expected} = MemorySpaces.provision_private_host(host_id, "scope:alpha")

    assert {:ok, partition} =
             Partition.resolve(%{
               kind: :client_token,
               client_id: "runtime-client",
               principal_metadata: %{"memory_partition_id" => "host:#{host_id}"}
             })

    assert partition.memory_space_id == expected.memory_space_id
    assert partition.host_id == host_id
    assert partition.client_id == "host:#{host_id}"
    assert partition.source_client_id == "runtime-client"
    assert partition.scope == "scope:alpha"
    assert partition.namespace == "private"
  end

  test "rejects a trusted metadata claim that conflicts with the entitled canonical owner" do
    host_id = insert_host("partition-conflict", "scope:alpha")
    assert {:ok, _partition} = MemorySpaces.provision_private_host(host_id, "scope:alpha")

    assert {:error, :unauthorized} =
             Partition.resolve(%{
               kind: :client_token,
               principal_metadata: %{
                 "memory_partition_id" => "host:#{host_id}",
                 "memory_space_id" => Ecto.UUID.generate()
               }
             })
  end

  test "pending exact-partition and initial-snapshot issues make readiness deterministic" do
    host_id = insert_host("partition-readiness", "scope:alpha")
    assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:alpha")

    issue =
      repo().insert!(%BackfillIssue{
        source_table: "initial_snapshot",
        source_id: "#{partition.memory_space_id}:scope:alpha:private",
        reason: "initial_snapshot_pending",
        disposition: "pending",
        details: %{
          "memory_space_id" => partition.memory_space_id,
          "scope" => "scope:alpha",
          "namespace" => "private"
        }
      })

    for _attempt <- 1..2 do
      assert {:error, :partition_not_ready} =
               MemorySpaces.resolve_host_partition(host_id, "scope:alpha", "private")
    end

    issue
    |> BackfillIssue.changeset(%{
      disposition: "resolved",
      resolved_at: DateTime.utc_now()
    })
    |> repo().update!()

    assert {:ok, ^partition} =
             MemorySpaces.resolve_host_partition(host_id, "scope:alpha", "private")
  end

  test "pending root issues with missing dimensions block the matching host deterministically" do
    host_id = insert_host("partition-missing-dimensions", "scope:alpha")
    assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:alpha")

    repo().insert!(%BackfillIssue{
      source_table: "bpm_memories",
      source_id: Ecto.UUID.generate(),
      reason: "missing_mapping",
      disposition: "pending",
      details: %{"host_id" => host_id, "scope" => nil, "namespace" => nil}
    })

    for _attempt <- 1..2 do
      assert {:error, :partition_not_ready} =
               MemorySpaces.resolve_host_partition(host_id, partition.scope, partition.namespace)
    end
  end

  test "revoked exact entitlement is unauthorized" do
    host_id = insert_host("partition-revoked", "scope:alpha")
    assert {:ok, _partition} = MemorySpaces.provision_private_host(host_id, "scope:alpha")
    assert :ok = MemorySpaces.revoke_host(host_id)

    assert {:error, :unauthorized} =
             MemorySpaces.resolve_host_partition(host_id, "scope:alpha", "private")
  end

  defp insert_host(name, memory_scope) do
    host_id = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO skill_hosts (id, name, memory_scope, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())",
      [Ecto.UUID.dump!(host_id), name, memory_scope]
    )

    host_id
  end
end
