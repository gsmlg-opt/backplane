defmodule Backplane.Memory.Operations.InventoryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Operations.Inventory

  test "trusted inventory globally orders, counts and pages across spaces without host registration" do
    a = canonical_partition("inventory-offline-a")
    b = canonical_partition("inventory-removed-b")
    older = memory(a, "shared older", ~U[2026-01-01 00:00:00.000000Z])
    newest = memory(b, "shared newest", ~U[2026-01-03 00:00:00.000000Z])
    middle = memory(a, "shared middle", ~U[2026-01-02 00:00:00.000000Z])
    memory(b, "unmatched", ~U[2026-01-04 00:00:00.000000Z])

    assert {:ok, %{entries: [first, second], total: 3, next_offset: 2}} =
             Inventory.memories(%{}, q: "shared", limit: 2)

    assert [first.id, second.id] == [newest.id, middle.id]

    assert {:ok, %{entries: [last], total: 3, next_offset: nil}} =
             Inventory.memories(%{}, q: "shared", limit: 2, offset: 2)

    assert last.id == older.id
    assert {:ok, identity} = Inventory.identity(:memory, newest.id)
    assert identity.memory_space_id == b.memory_space_id
    assert identity.host_id == b.host_id

    assert {:ok, %{entries: [oldest, next], total: 3}} =
             Inventory.memories(%{}, q: "shared", sort: "oldest", limit: 2)

    assert [oldest.id, next.id] == [older.id, middle.id]
  end

  test "optional source and repository predicates apply before pagination and count" do
    a = canonical_partition("inventory-source-a")
    b = canonical_partition("inventory-source-b")
    one = memory(a, "source one", ~U[2026-01-01 00:00:00.000000Z], "github.com/example/one")
    memory(b, "source two", ~U[2026-01-02 00:00:00.000000Z], "github.com/example/two")
    memory(a, "legacy unknown repository", ~U[2026-01-03 00:00:00.000000Z])

    assert {:ok, %{entries: [found], total: 1}} =
             Inventory.memories(%{repository: "github.com/example/one"}, limit: 1)

    assert found.id == one.id
    assert {:ok, %{total: 2}} = Inventory.memories(%{host_id: a.host_id})

    assert {:ok, %{total: 1}} =
             Inventory.memories(Map.take(b, [:memory_space_id, :scope, :namespace]))

    assert {:ok, %{entries: [], total: 0}} = Inventory.memories(%{host_id: "missing"})
  end

  test "empty unregistered installations are a successful bounded inventory" do
    assert {:ok, %{entries: [], total: 0, next_offset: nil}} = Inventory.memories(%{})
    assert {:error, :invalid_options} = Inventory.memories(%{}, limit: 101)
    assert {:error, :not_found} = Inventory.identity(:memory, "invalid")
  end

  test "audit target predicates and counts precede global pagination" do
    a = canonical_partition("inventory-audit-a")
    b = canonical_partition("inventory-audit-b")
    id = Ecto.UUID.generate()

    Backplane.Memory.Audit.log(
      "remember",
      "operator",
      %{memory_id: id},
      Map.new(a, fn {k, v} -> {to_string(k), v} end)
    )

    Backplane.Memory.Audit.log(
      "remember",
      "operator",
      [Ecto.UUID.generate()],
      Map.new(b, fn {k, v} -> {to_string(k), v} end)
    )

    assert {:ok, %{entries: [row], total: 1}} = Inventory.audit(%{}, target: id, limit: 1)
    assert row.actor == "operator"
    assert {:ok, %{total: 1}} = Inventory.audit(%{host_id: a.host_id})
    assert {:ok, %{entries: [], total: 1}} = Inventory.audit(%{}, target: id, offset: 1)
  end

  test "repository filtering follows profile source IDs rather than unrelated equal project paths" do
    alias Backplane.Memory.Profiles.Profile
    partition = canonical_partition("inventory-profile")

    source =
      memory(partition, "recorded source", ~U[2026-01-01 00:00:00.000000Z], "git.example/one")

    unrelated =
      memory(
        partition,
        "same path different source",
        ~U[2026-01-02 00:00:00.000000Z],
        "git.example/two"
      )

    for record <- [source, unrelated] do
      record
      |> Ecto.Changeset.change(metadata: Map.put(record.metadata, "project", "/same/path"))
      |> repo().update!()
    end

    profile =
      %Profile{}
      |> Profile.changeset(
        Map.merge(partition, %{
          project: "/same/path",
          updated_at: DateTime.utc_now(),
          source_records: %{"memory_ids" => [source.id]}
        })
      )
      |> repo().insert!()

    assert {:ok, %{entries: [found], total: 1}} =
             Inventory.profiles(%{repository: "git.example/one"})

    assert found.id == profile.id
    assert {:ok, %{entries: [], total: 0}} = Inventory.profiles(%{repository: "git.example/two"})
  end

  defp memory(partition, content, at, repository \\ nil) do
    metadata =
      if repository, do: %{"repository_sources" => [%{"repository_id" => repository}]}, else: %{}

    %Memory{}
    |> Memory.changeset(
      Map.merge(partition, %{
        content: content,
        memory_type: "semantic",
        agent_id: "inventory-test",
        metadata: metadata
      })
    )
    |> Ecto.Changeset.put_change(:inserted_at, at)
    |> repo().insert!()
  end
end
