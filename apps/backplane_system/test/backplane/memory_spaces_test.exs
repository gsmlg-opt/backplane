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

    test "the database rejects a second active default for a host namespace" do
      host_id = insert_host("ambiguous", "scope:a")
      assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:a")

      assert {:error, changeset} =
               %Entitlement{}
               |> Entitlement.changeset(%{
                 memory_space_id: partition.memory_space_id,
                 host_id: host_id,
                 scope: "scope:b",
                 namespace: "private",
                 default_capture: true,
                 status: "active"
               })
               |> Repo.insert()

      assert {"has already been taken", metadata} = changeset.errors[:default_capture]
      assert metadata[:constraint_name] == "bpm_memory_space_entitlements_active_default_index"
    end

    test "defensively rejects ambiguous defaults in deliberately corrupted state" do
      host_id = insert_host("corrupted-defaults", "scope:a")
      assert {:ok, partition} = MemorySpaces.provision_private_host(host_id, "scope:a")

      Repo.query!("DROP INDEX bpm_memory_space_entitlements_active_default_index")

      Repo.insert!(%Entitlement{
        memory_space_id: partition.memory_space_id,
        host_id: host_id,
        scope: "scope:b",
        namespace: "private",
        default_capture: true,
        status: "active",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      assert {:error, :ambiguous_partition} =
               MemorySpaces.resolve_host_partition(host_id, nil, "private")
    end

    test "rejects revoked access, blanks, and missing mappings" do
      host_id = insert_host("revoked", "scope:a")
      assert {:ok, _partition} = MemorySpaces.provision_private_host(host_id, "scope:a")

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

    test "concurrent scope updates retain one resolvable active default" do
      real_repo = start_real_repo!()
      host_id = Ecto.UUID.generate()
      parent = self()

      try do
        with_dynamic_repo(real_repo, fn ->
          insert_host("concurrent-#{host_id}", "scope:initial", host_id)
          assert {:ok, _partition} = MemorySpaces.provision_private_host(host_id, "scope:initial")
        end)

        tasks =
          for scope <- ["scope:first", "scope:second"] do
            Task.async(fn ->
              Repo.put_dynamic_repo(real_repo)
              send(parent, {:scope_update_ready, self()})

              receive do
                :run_scope_update -> :ok
              end

              MemorySpaces.update_default_scope(host_id, scope)
            end)
          end

        task_pids =
          for _task <- tasks do
            assert_receive {:scope_update_ready, task_pid}
            task_pid
          end

        Enum.each(task_pids, &send(&1, :run_scope_update))
        assert Enum.map(tasks, &Task.await(&1, 5_000)) == [:ok, :ok]

        with_dynamic_repo(real_repo, fn ->
          defaults =
            Repo.all(
              from(entitlement in Entitlement,
                where:
                  entitlement.host_id == ^host_id and entitlement.namespace == "private" and
                    entitlement.status == "active" and
                    entitlement.default_capture == true
              )
            )

          assert [%Entitlement{} = sole_default] = defaults

          assert {:ok, resolved} =
                   MemorySpaces.resolve_host_partition(host_id, nil, "private")

          assert resolved.scope == sole_default.scope
          assert resolved.memory_space_id == sole_default.memory_space_id
        end)
      after
        with_dynamic_repo(real_repo, fn -> cleanup_real_repo_host(host_id) end)
        GenServer.stop(real_repo)
      end
    end
  end

  defp insert_host(name, memory_scope, id \\ Ecto.UUID.generate()) do
    Repo.query!(
      "INSERT INTO skill_hosts (id, name, memory_scope, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())",
      [Ecto.UUID.dump!(id), name, memory_scope]
    )

    id
  end

  defp start_real_repo! do
    {:ok, repo} =
      Repo.start_link(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 4
      )

    repo
  end

  defp with_dynamic_repo(repo, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp cleanup_real_repo_host(host_id) do
    space_id = MemorySpaces.private_host_space_id(host_id)
    alias_value = "host:#{host_id}"

    Repo.delete_all(from(entitlement in Entitlement, where: entitlement.host_id == ^host_id))
    Repo.delete_all(from(alias_row in LegacyAlias, where: alias_row.alias_value == ^alias_value))
    Repo.delete_all(from(space in MemorySpace, where: space.id == ^space_id))
    Repo.query!("DELETE FROM skill_hosts WHERE id = $1", [Ecto.UUID.dump!(host_id)])
  end
end
