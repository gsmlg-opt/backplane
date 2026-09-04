defmodule Backplane.MemorySpacesTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.{Entitlement, LegacyAlias, MemorySpace}
  alias Backplane.Repo

  describe "private host provisioning" do
    test "provisions one stable private space, alias, and default entitlement" do
      host_id = insert_host("stable-host", "project:alpha")

      assert {:ok, first} = MemorySpaces.provision_private_host(host_id, " project:alpha ")
      assert {:ok, second} = MemorySpaces.provision_private_host(host_id, "project:alpha")

      assert first == second
      assert first.scope == "project:alpha"
      assert first.namespace == "private"

      assert %MemorySpace{kind: "private", status: "active"} =
               Repo.get!(MemorySpace, first.memory_space_id)

      assert [%LegacyAlias{alias_type: "host", alias_value: alias_value}] =
               Repo.all(LegacyAlias)

      assert alias_value == "host:#{host_id}"

      assert [
               %Entitlement{
                 host_id: ^host_id,
                 scope: "project:alpha",
                 namespace: "private",
                 default_capture: true,
                 status: "active"
               }
             ] = Repo.all(Entitlement)
    end

    test "participates in the caller transaction" do
      host_id = Ecto.UUID.generate()

      assert {:error, :forced_rollback} =
               Repo.transaction(fn ->
                 insert_host("rolled-back-host", "proj_local", host_id)

                 assert {:ok, _partition} =
                          MemorySpaces.provision_private_host(host_id, "proj_local")

                 Repo.rollback(:forced_rollback)
               end)

      assert Repo.get(MemorySpace, MemorySpaces.private_host_space_id(host_id)) == nil
      alias_value = "host:#{host_id}"

      refute Repo.exists?(
               from(alias_row in LegacyAlias, where: alias_row.alias_value == ^alias_value)
             )
    end
  end

  describe "partition resolution" do
    test "resolves an exact active entitlement and the sole active default" do
      host_id = insert_host("resolver", "scope:a")
      assert {:ok, expected} = MemorySpaces.provision_private_host(host_id, "scope:a")

      assert {:ok, ^expected} = MemorySpaces.resolve_host_partition(host_id, "scope:a", "private")
      assert {:ok, ^expected} = MemorySpaces.resolve_host_partition(host_id, nil, "private")
    end

    test "scope changes preserve active history and move the sole default" do
      host_id = insert_host("scope-change", "scope:old")
      assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:old")

      assert :ok = MemorySpaces.update_default_scope(host_id, " scope:new ")

      entitlements =
        Entitlement
        |> where([entitlement], entitlement.host_id == ^host_id)
        |> order_by(:scope)
        |> Repo.all()

      assert Enum.map(entitlements, &{&1.scope, &1.status, &1.default_capture}) == [
               {"scope:new", "active", true},
               {"scope:old", "active", false}
             ]

      assert {:ok, %{memory_space_id: id, scope: "scope:new", namespace: "private"}} =
               MemorySpaces.resolve_host_partition(host_id, nil, "private")

      assert id == partition.memory_space_id

      assert {:ok, %{scope: "scope:old"}} =
               MemorySpaces.resolve_host_partition(host_id, "scope:old", "private")
    end

    test "rejects ambiguous defaults, revoked access, blanks, and missing mappings" do
      host_id = insert_host("ambiguous", "scope:a")
      assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:a")

      now = DateTime.utc_now()

      Repo.insert!(%Entitlement{
        memory_space_id: partition.memory_space_id,
        host_id: host_id,
        scope: "scope:b",
        namespace: "private",
        default_capture: true,
        status: "active",
        inserted_at: now,
        updated_at: now
      })

      assert {:error, :ambiguous_partition} =
               MemorySpaces.resolve_host_partition(host_id, nil, "private")

      assert {:error, :unauthorized} =
               MemorySpaces.resolve_host_partition(host_id, "scope:missing", "private")

      assert {:error, :unauthorized} =
               MemorySpaces.resolve_host_partition(host_id, "   ", "private")

      assert {:error, :unauthorized} =
               MemorySpaces.resolve_host_partition(host_id, "scope:a", "   ")

      assert :ok = MemorySpaces.revoke_host(host_id)

      assert {:error, :unauthorized} =
               MemorySpaces.resolve_host_partition(host_id, "scope:a", "private")

      missing_host_id = Ecto.UUID.generate()

      assert {:error, :partition_not_ready} =
               MemorySpaces.resolve_host_partition(missing_host_id, nil, "private")
    end
  end

  defp insert_host(name, memory_scope, id \\ Ecto.UUID.generate()) do
    Repo.query!(
      "INSERT INTO skill_hosts (id, name, memory_scope, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())",
      [Ecto.UUID.dump!(id), name, memory_scope]
    )

    id
  end
end
