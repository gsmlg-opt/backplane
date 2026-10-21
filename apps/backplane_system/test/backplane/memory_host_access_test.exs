defmodule Backplane.MemoryHostAccessTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.{BackfillIssue, Entitlement}

  setup do
    [owner, recipient] = for _ <- 1..2, do: insert_host!()
    {:ok, partition} = MemorySpaces.provision_private_host(owner, "owner-scope")
    {:ok, private} = MemorySpaces.provision_private_host(recipient, "recipient-scope")
    %{owner: owner, host: recipient, partition: partition, private: private}
  end

  test "capabilities are independent, exact, typed, and do not move private defaults", c do
    for caps <- [[:read], [:remember], [:forget], [:read, :deliver]] do
      partition = %{c.partition | scope: "caps-#{Enum.join(caps, "-")}"}
      assert {:ok, access} = grant(c.host, partition, caps)
      assert access.partition == partition
      assert access.capabilities == Enum.sort(caps)
      assert access.status == :active
      assert access.authority_version == 1
      refute access.default_capture
      assert access.offline_read_lease_seconds == 0

      for operation <- [:read, :deliver, :remember, :forget] do
        result =
          MemorySpaces.resolve_host_access(c.host, {:access_id, access.access_id}, operation)

        if operation in caps,
          do: assert({:ok, _} = result),
          else: assert(result == {:error, :unauthorized})
      end
    end

    assert {:ok, private} = MemorySpaces.resolve_host_access(c.host, :default, :read)
    assert private.partition == c.private
    assert private.default_capture
    assert {:ok, ^private} = MemorySpaces.resolve_host_access(c.host, :default, :remember)
  end

  test "rejects malformed capabilities, invalid leases, operator and target escalation", c do
    for caps <- [[:deliver], [:read, :read], ["read"], [:admin], :read] do
      assert {:error, :invalid_request} = grant(c.host, c.partition, caps)
    end

    for {caps, lease} <- [
          {[:read], 1},
          {[:remember], 1},
          {[:read, :deliver], -1},
          {[:read, :deliver], 301}
        ] do
      assert {:error, :invalid_request} =
               grant(c.host, c.partition, caps, offline_read_lease_seconds: lease)
    end

    assert {:error, :invalid_request} = grant(c.host, c.partition, [:read], reason: " ")

    assert {:error, :invalid_request} =
             MemorySpaces.grant_host_access(%{}, c.host, c.partition, [:read],
               reason: "x",
               expected_version: 0
             )

    assert {:error, :invalid_request} =
             grant(c.host, Map.put(c.partition, :default_capture, true), [:read])

    assert {:error, :unauthorized} = grant(Ecto.UUID.generate(), c.partition, [:read])

    assert {:error, :unauthorized} =
             grant(c.host, %{c.partition | memory_space_id: Ecto.UUID.generate()}, [:read])

    assert {:error, :invalid_request} = grant(c.host, c.partition, [:read], expected_version: nil)
  end

  test "CAS, no-op, revoke and regrant retain identity and monotonic versions", c do
    assert {:ok, first} = grant(c.host, c.partition, [:read])
    assert {:error, :version_conflict} = grant(c.host, c.partition, [:read])
    assert {:ok, ^first} = grant(c.host, c.partition, [:read], expected_version: 1)
    assert length(audits(first.access_id)) == 1

    assert {:error, :version_conflict} =
             MemorySpaces.change_host_access(
               operator(),
               first.access_id,
               99,
               %{capabilities: [:remember]},
               "change"
             )

    assert {:error, :invalid_request} =
             MemorySpaces.change_host_access(
               operator(),
               first.access_id,
               1,
               %{default_capture: true},
               "change"
             )

    assert {:ok, changed} =
             MemorySpaces.change_host_access(
               operator(),
               first.access_id,
               1,
               %{capabilities: [:remember]},
               "write only"
             )

    assert changed.authority_version == 2
    assert changed.capabilities == [:remember]

    assert {:ok, revoked} =
             MemorySpaces.revoke_host_access(operator(), first.access_id, 2, "withdraw")

    assert revoked.status == :revoked
    assert revoked.authority_version == 3
    assert revoked.capabilities == [:remember]

    assert {:ok, ^revoked} =
             MemorySpaces.revoke_host_access(operator(), first.access_id, 3, "already revoked")

    assert length(audits(first.access_id)) == 3

    assert {:error, :unauthorized} =
             MemorySpaces.resolve_host_access(c.host, {:access_id, first.access_id}, :remember)

    assert {:ok, regrant} = grant(c.host, c.partition, [:forget], expected_version: 3)
    assert regrant.access_id == first.access_id
    assert regrant.authority_version == 4
    assert Enum.map(audits(first.access_id), & &1.new_authority_version) == [1, 2, 3, 4]
  end

  test "lease changes increment authority and admin lists alone expose latest reason", c do
    assert {:ok, first} =
             grant(c.host, c.partition, [:read, :deliver], offline_read_lease_seconds: 300)

    assert {:ok, changed} =
             MemorySpaces.change_host_access(
               operator(),
               first.access_id,
               1,
               %{offline_read_lease_seconds: 0},
               "online only"
             )

    assert changed.authority_version == 2
    refute Map.has_key?(changed, :latest_audit_reason)
    assert {:ok, accesses} = MemorySpaces.list_host_access(c.host)

    assert Enum.find(accesses, &(&1.access_id == first.access_id)).latest_audit_reason ==
             "online only"

    assert {:ok, listed_accesses} = MemorySpaces.list_partition_access(c.partition)
    listed = Enum.find(listed_accesses, &(&1.access_id == first.access_id))
    assert listed.latest_audit_reason == "online only"

    assert {:ok, resolved} =
             MemorySpaces.resolve_host_access(c.host, {:access_id, first.access_id}, :read)

    refute Map.has_key?(resolved, :latest_audit_reason)
    refute Map.has_key?(resolved, :actor)
  end

  test "selectors fail closed without revealing foreign, revoked or unknown grants", c do
    {:ok, access} = grant(c.host, c.partition, [:remember])

    for {host, selector, op, expected} <- [
          {c.owner, {:access_id, access.access_id}, :remember, :unauthorized},
          {c.host, {:access_id, Ecto.UUID.generate()}, :read, :unauthorized},
          {c.host, {:access_id, "bad"}, :read, :invalid_request},
          {c.host, :default, :facet_query, :invalid_request},
          {c.host, {:access_id, access.access_id}, :read, :unauthorized}
        ] do
      assert {:error, ^expected} = MemorySpaces.resolve_host_access(host, selector, op)
    end
  end

  test "locked wrapper requires real internal credential validation and exact versions", c do
    {:ok, access} = grant(c.host, c.partition, [:remember])
    actor = actor(c.host)

    fun = fn context ->
      assert context.actor == Map.take(actor, [:host_id, :credential_id, :source_client_id])
      refute Map.has_key?(context.actor, :credential_check)
      refute Map.has_key?(context, :latest_audit_reason)
      {:ok, context.access_id}
    end

    assert {:ok, id} =
             MemorySpaces.with_host_access(
               actor,
               {:access_id, access.access_id},
               :remember,
               1,
               fun
             )

    assert id == access.access_id

    assert {:error, :authority_changed} =
             MemorySpaces.with_host_access(actor, {:access_id, id}, :remember, 2, fun)

    assert {:error, :invalid_request} =
             MemorySpaces.with_host_access(actor, {:access_id, id}, :remember, nil, fun)

    assert {:ok, :private} =
             MemorySpaces.with_host_access(actor, :default, :read, nil, fn _ ->
               {:ok, :private}
             end)

    checks = [
      nil,
      fn _ -> false end,
      fn _ -> nil end,
      fn _ -> {:error, :unauthorized} end,
      fn _ -> raise "credential error" end,
      fn _ -> throw(:bad) end
    ]

    for check <- checks do
      assert {:error, :unauthorized} =
               MemorySpaces.with_host_access(
                 Map.put(actor, :credential_check, check),
                 {:access_id, id},
                 :remember,
                 1,
                 fn _ -> flunk("unauthorized callback reached operation") end
               )
    end

    assert {:error, :unauthorized} =
             MemorySpaces.with_host_access(
               Map.delete(actor, :credential_check),
               {:access_id, id},
               :remember,
               1,
               fun
             )
  end

  test "locked wrapper rolls back callback errors in the same transaction", c do
    {:ok, access} = grant(c.host, c.partition, [:remember])

    assert {:error, :forced} =
             MemorySpaces.with_host_access(
               actor(c.host),
               {:access_id, access.access_id},
               :remember,
               1,
               fn _ ->
                 Repo.query!("UPDATE skill_hosts SET name = 'must rollback' WHERE id = $1", [
                   Ecto.UUID.dump!(c.host)
                 ])

                 {:error, :forced}
               end
             )

    assert %{rows: [[name]]} =
             Repo.query!("SELECT name FROM skill_hosts WHERE id = $1", [Ecto.UUID.dump!(c.host)])

    refute name == "must rollback"
  end

  test "authority and audit roll back together when audit insertion fails", c do
    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_access_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'forced access audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_access_audit BEFORE INSERT ON bpm_memory_access_audits FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_access_audit()"
    )

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> grant(c.host, c.partition, [:read]) end, mode: :savepoint)
    end

    refute Repo.exists?(
             from e in Entitlement,
               where: e.host_id == ^c.host and e.memory_space_id == ^c.partition.memory_space_id
           )
  end

  test "private provisioning and scope updates cannot revive a revoked entitlement", c do
    {:ok, private} = MemorySpaces.resolve_host_access(c.host, :default, :read)

    assert {:ok, revoked} =
             MemorySpaces.revoke_host_access(operator(), private.access_id, 1, "stop private")

    assert {:error, :unauthorized} = MemorySpaces.provision_private_host(c.host, c.private.scope)
    assert {:error, :unauthorized} = MemorySpaces.update_default_scope(c.host, c.private.scope)

    assert Repo.get!(Entitlement, private.access_id).authority_version ==
             revoked.authority_version

    assert Repo.get!(Entitlement, private.access_id).status == "revoked"
  end

  test "legacy inventory remains alias-backed and foreign disposition is exact", c do
    foreign =
      Repo.insert!(%Entitlement{
        host_id: c.host,
        memory_space_id: c.partition.memory_space_id,
        scope: c.partition.scope,
        namespace: c.partition.namespace
      })

    issue =
      Repo.insert!(%BackfillIssue{
        source_table: "bpm_memory_space_entitlements",
        source_id: foreign.id,
        reason: "shared_access_requires_disposition",
        details:
          Map.new(c.partition, fn {k, v} -> {to_string(k), v} end) |> Map.put("host_id", c.host)
      })

    assert {:ok, [private]} = MemorySpaces.host_entitlements(c.host)
    assert private == c.private

    assert {:error, :unauthorized} =
             MemorySpaces.resolve_host_access(c.host, {:access_id, foreign.id}, :read)

    assert {:ok, access} = grant(c.host, c.partition, [:read], expected_version: 1)
    assert access.access_id == foreign.id
    assert Repo.get!(BackfillIssue, issue.id).disposition == "resolved"
    assert {:ok, [^private]} = MemorySpaces.host_entitlements(c.host)

    assert {:ok, _} =
             MemorySpaces.resolve_host_access(c.host, {:access_id, access.access_id}, :read)
  end

  test "host-wide revoke increments and audits effective rows exactly once", c do
    {:ok, shared} = grant(c.host, c.partition, [:forget])
    {:ok, private} = MemorySpaces.resolve_host_access(c.host, :default, :read)
    assert :ok = MemorySpaces.revoke_host(c.host)
    assert :ok = MemorySpaces.revoke_host(c.host)

    for id <- [shared.access_id, private.access_id] do
      row = Repo.get!(Entitlement, id)
      assert row.status == "revoked"
      assert row.authority_version == 2
      refute row.default_capture

      assert Enum.count(audits(id), &(&1.action == "host_revoke" and &1.actor_kind == "system")) ==
               1
    end
  end

  test "initial snapshot issues remain enumerable for existing private mirror recovery", c do
    Repo.insert!(%BackfillIssue{
      source_table: "initial_snapshot",
      source_id: Ecto.UUID.generate(),
      reason: "snapshot_required",
      details:
        Map.new(c.private, fn {k, v} -> {to_string(k), v} end) |> Map.put("host_id", c.host)
    })

    assert {:ok, [private]} = MemorySpaces.host_entitlements(c.host)
    assert private == c.private
    refute MemorySpaces.partition_ready?(c.host, c.private)
    assert MemorySpaces.partition_ready?(c.host, c.private, true)
  end

  test "locked host access serializes concurrent revoke until the operation transaction ends" do
    with_real_fixture(fn c ->
      {:ok, access} = grant(c.host, c.partition, [:remember])
      parent = self()

      actor =
        Map.put(actor(c.host), :credential_check, fn _ ->
          send(parent, {:credential_locked, self()})

          receive do
            :release_access -> :ok
          after
            5_000 -> {:error, :unauthorized}
          end
        end)

      reader =
        Task.async(fn ->
          Repo.put_dynamic_repo(c.repo)

          MemorySpaces.with_host_access(
            actor,
            {:access_id, access.access_id},
            :remember,
            1,
            fn _ -> {:ok, :committed} end
          )
        end)

      assert_receive {:credential_locked, reader_pid}, 2_000

      revoker =
        Task.async(fn ->
          Repo.put_dynamic_repo(c.repo)
          send(parent, :revoke_started)
          MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "concurrent revoke")
        end)

      assert_receive :revoke_started
      assert Task.yield(revoker, 100) == nil
      send(reader_pid, :release_access)
      assert Task.await(reader, 5_000) == {:ok, :committed}
      assert {:ok, %{authority_version: 2, status: :revoked}} = Task.await(revoker, 5_000)

      assert {:error, :unauthorized} =
               MemorySpaces.with_host_access(
                 actor(c.host),
                 {:access_id, access.access_id},
                 :remember,
                 1,
                 fn _ -> flunk("revoked operation ran") end
               )
    end)
  end

  test "concurrent operator CAS admits only one transition" do
    with_real_fixture(fn c ->
      {:ok, access} = grant(c.host, c.partition, [:read])

      tasks =
        for caps <- [[:remember], [:forget]] do
          Task.async(fn ->
            Repo.put_dynamic_repo(c.repo)

            MemorySpaces.change_host_access(
              operator(),
              access.access_id,
              1,
              %{capabilities: caps},
              "CAS race"
            )
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5_000))
      assert Enum.count(results, &match?({:ok, %{authority_version: 2}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :version_conflict})) == 1
      assert Enum.map(audits(access.access_id), & &1.new_authority_version) == [1, 2]
    end)
  end

  test "notifications wait for the outer commit and disappear on rollback" do
    with_real_fixture(fn c ->
      opts =
        Keyword.take(Repo.config(), [
          :hostname,
          :port,
          :username,
          :password,
          :database,
          :ssl,
          :socket_dir
        ])

      {:ok, listener} = Postgrex.Notifications.start_link(opts)

      try do
        {:ok, _} = Postgrex.Notifications.listen(listener, "bpm_memory_access_changed")

        assert {:error, :forced} =
                 Repo.transaction(fn ->
                   assert {:ok, _} = grant(c.host, c.partition, [:read])
                   refute_receive {:notification, _, _, "bpm_memory_access_changed", _}, 50
                   Repo.rollback(:forced)
                 end)

        refute_receive {:notification, _, _, "bpm_memory_access_changed", _}, 100
        assert {:ok, access} = grant(c.host, c.partition, [:read])
        assert_receive {:notification, ^listener, _, "bpm_memory_access_changed", payload}, 2_000

        assert Jason.decode!(payload) == %{
                 "host_id" => c.host,
                 "access_id" => access.access_id,
                 "authority_version" => 1,
                 "status" => "active"
               }
      after
        GenServer.stop(listener)
      end
    end)
  end

  defp with_real_fixture(fun) do
    {:ok, repo} = Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)
    previous = Repo.put_dynamic_repo(repo)
    hosts = for _ <- 1..2, do: insert_host!()
    [owner, host] = hosts
    {:ok, partition} = MemorySpaces.provision_private_host(owner, "real-owner")
    {:ok, _} = MemorySpaces.provision_private_host(host, "real-recipient")

    try do
      fun.(%{repo: repo, host: host, partition: partition})
    after
      Repo.delete_all(from e in Entitlement, where: e.host_id in ^hosts)

      for host_id <- hosts do
        value = "host:" <> host_id

        Repo.delete_all(
          from a in Backplane.MemorySpaces.LegacyAlias, where: a.alias_value == ^value
        )

        id = MemorySpaces.private_host_space_id(host_id)
        Repo.delete_all(from s in Backplane.MemorySpaces.MemorySpace, where: s.id == ^id)
        Repo.query!("DELETE FROM skill_hosts WHERE id = $1", [Ecto.UUID.dump!(host_id)])
      end

      Repo.put_dynamic_repo(previous)
      GenServer.stop(repo)
    end
  end

  defp operator, do: %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

  defp grant(host, partition, caps, opts \\ []),
    do:
      MemorySpaces.grant_host_access(
        operator(),
        host,
        partition,
        caps,
        Keyword.merge([reason: "explicit grant", expected_version: 0], opts)
      )

  defp actor(host),
    do: %{
      host_id: host,
      credential_id: Ecto.UUID.generate(),
      source_client_id: "test-client",
      credential_check: fn _ -> :ok end
    }

  defp audits(id) do
    Repo.all(
      from a in "bpm_memory_access_audits",
        where: a.access_id == type(^id, :binary_id),
        order_by: [a.new_authority_version],
        select: %{
          action: a.action,
          actor_kind: a.actor_kind,
          new_authority_version: a.new_authority_version
        }
    )
  end

  defp insert_host! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_hosts (id, name, memory_scope, inserted_at, updated_at) VALUES ($1, $2, 'proj_local', now(), now())",
      [Ecto.UUID.dump!(id), "shared-test-#{id}"]
    )

    id
  end
end
