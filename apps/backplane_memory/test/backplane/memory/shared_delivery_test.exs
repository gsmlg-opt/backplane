defmodule Backplane.Memory.SharedDeliveryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Memory.EdgeSync
  alias EdgeSync.{Cursor, Delivery}

  setup do
    previous = Backplane.Settings.get("memory.host_sync_v2.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", previous}) end)
    fixture()
  end

  test "extended inventory is complete, effective, bounded and private peers stay private", c do
    access = grant(c, [:read, :deliver, :remember, :forget])
    assert {:ok, inventory} = EdgeSync.negotiate(c.auth, offer())
    assert inventory.extensions == ["memory_access.v1", "memory_commands.v2"]
    assert length(inventory.accesses) == 2
    assert Enum.any?(inventory.accesses, &(&1.access_id == access.access_id))
    refute inventory.default_access_id == access.access_id
    assert Enum.any?(inventory.partitions, &(&1["access_id"] == access.access_id))

    assert {:ok, import_only} =
             EdgeSync.negotiate(%{c.auth | scopes: ["host_agent.import"]}, offer())

    assert import_only.partitions == []
    assert Enum.all?(import_only.accesses, &(&1.capabilities == [:forget, :remember]))
    assert {:ok, no_scopes} = EdgeSync.negotiate(%{c.auth | scopes: []}, offer())
    assert no_scopes.partitions == []
    assert Enum.all?(no_scopes.accesses, &(&1.capabilities == []))
    assert {:ok, legacy} = EdgeSync.negotiate(c.host, offer(false))
    refute Map.has_key?(legacy, :accesses)
    refute Enum.any?(legacy.partitions, &(&1["memory_space_id"] == c.partition.memory_space_id))

    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.negotiate(c.auth, put_in(offer(), ["memory_v2", "max_frame_bytes"], 50))

    Repo.query!(
      """
      INSERT INTO bpm_memory_space_entitlements
        (id,memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at)
      SELECT gen_random_uuid(),$1,$2,'overflow-' || n,'private','active',now(),now()
      FROM generate_series(1,1001) n
      """,
      [Ecto.UUID.dump!(c.partition.memory_space_id), Ecto.UUID.dump!(c.host)]
    )

    assert {:error, %{code: :payload_too_large}} = EdgeSync.negotiate(c.auth, offer())
  end

  test "delivery, current and duplicate ACK bind exact authority while preserving source", c do
    access = grant(c, [:read, :deliver])
    memory = seed(c)
    request = request(c, access)
    assert {:ok, batch} = EdgeSync.next(c.auth, request)
    assert batch["access"] == request["access"]
    assert Enum.any?(batch["items"], &(&1["canonical_id"] == memory.id))
    assert {:ok, %{host_id: source}} = Backplane.Memory.Memories.get(memory.id, c.partition)
    assert source == c.owner
    assert {:ok, ^batch} = EdgeSync.next(c.auth, request)
    assert {:ok, acked} = EdgeSync.ack(c.auth, ack(request, batch))
    assert acked.status == :advanced
    assert acked.access == request["access"]
    assert acked.partition == request["partition"]
    assert acked.batch_id == batch["batch_id"]
    assert acked.snapshot_id == batch["snapshot_id"]
    assert acked.chunk_hash == batch["chunk_hash"]
    assert acked.integrity_hash == batch["integrity_hash"]
    assert {:ok, %{status: :duplicate, batch_id: id}} = EdgeSync.ack(c.auth, ack(request, batch))
    assert id == batch["batch_id"]

    assert {:ok, current} =
             EdgeSync.next(c.auth, %{request | "applied_revision" => batch["to_revision"]})

    assert current["status"] == "current"
    assert current["access"] == request["access"]
  end

  test "read-only cannot deliver and current credentials are rechecked", c do
    access = grant(c, [:read])
    assert {:error, %{code: :unauthorized}} = EdgeSync.next(c.auth, request(c, access))

    assert {:ok, access} =
             MemorySpaces.change_host_access(
               operator(),
               access.access_id,
               1,
               %{capabilities: [:read, :deliver]},
               "enable feed"
             )

    assert {:error, %{code: :unauthorized}} =
             EdgeSync.next(%{c.auth | scopes: ["host_agent.import"]}, request(c, access))

    Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
      Ecto.UUID.dump!(c.token)
    ])

    assert {:error, %{code: :unauthorized}} = EdgeSync.next(c.auth, request(c, access))
    assert {:error, %{code: :unauthorized}} = EdgeSync.negotiate(c.auth, offer())
  end

  test "authority generation invalidates old batch, continuation and ACK, requiring snapshot",
       c do
    access = grant(c, [:read, :deliver])
    seed(c)
    old_request = request(c, access)
    assert {:ok, old} = EdgeSync.next(c.auth, old_request)
    assert {:ok, _} = MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "withdraw")
    assert {:error, %{code: :unauthorized}} = EdgeSync.next(c.auth, old_request)
    assert {:error, %{code: :unauthorized}} = EdgeSync.ack(c.auth, ack(old_request, old))

    assert {:ok, fresh_access} =
             MemorySpaces.grant_host_access(operator(), c.host, c.partition, [:read, :deliver],
               expected_version: 2,
               reason: "fresh generation"
             )

    assert {:error, %{code: :authority_changed}} = EdgeSync.next(c.auth, old_request)
    fresh_request = request(c, fresh_access)

    assert {:error, %{code: :invalid_ack}} =
             EdgeSync.ack(
               c.auth,
               Map.put(ack(old_request, old), "access", fresh_request["access"])
             )

    assert {:error, %{code: :authority_changed}} =
             EdgeSync.next(
               c.auth,
               Map.merge(fresh_request, %{
                 "snapshot_id" => old["snapshot_id"],
                 "next_chunk_index" => 1
               })
             )

    assert {:ok, fresh} = EdgeSync.next(c.auth, fresh_request)
    assert fresh["kind"] == "snapshot_chunk"
    assert fresh["batch_id"] != old["batch_id"]
    assert fresh["chunk_index"] == 0
    assert fresh["access"] == fresh_request["access"]
    assert Repo.get!(Delivery, old["batch_id"]).status == "expired"

    cursor =
      Repo.one!(
        from cur in Cursor,
          where: cur.host_id == ^c.host and cur.memory_space_id == ^c.partition.memory_space_id
      )

    assert cursor.access_id == access.access_id
    assert cursor.authority_version == 3
    assert cursor.applied_revision == 0
  end

  test "next and ACK keep authority locked until their outer transaction ends" do
    for operation <- [:next, :ack] do
      with_real_fixture(fn c ->
        access = grant(c, [:read, :deliver])
        request = request(c, access)
        parent = self()

        delivery =
          Task.async(fn ->
            Repo.put_dynamic_repo(c.repo)

            Repo.transaction(fn ->
              assert {:ok, batch} = EdgeSync.next(c.auth, request)

              if operation == :ack do
                assert {:ok, %{status: :advanced}} = EdgeSync.ack(c.auth, ack(request, batch))
              end

              send(parent, {:delivery_locked, self(), batch["batch_id"]})

              receive do
                :release_delivery -> Repo.rollback(:race_cleanup)
              after
                5_000 -> raise "delivery release timeout"
              end
            end)
          end)

        try do
          assert_receive {:delivery_locked, worker, batch_id}, 5_000

          revoker =
            Task.async(fn ->
              Repo.put_dynamic_repo(c.repo)

              Repo.transaction(fn ->
                %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
                send(parent, {:revoke_backend, backend})

                MemorySpaces.revoke_host_access(
                  operator(),
                  access.access_id,
                  1,
                  "delivery race revoke"
                )
              end)
            end)

          try do
            assert_receive {:revoke_backend, backend}, 2_000
            assert wait_for_lock(backend, 100)
            refute Task.yield(revoker, 20)
            send(worker, :release_delivery)
            assert {:error, :race_cleanup} = Task.await(delivery, 5_000)
            assert {:ok, {:ok, %{status: :revoked}}} = Task.await(revoker, 5_000)
            refute Repo.get(Delivery, batch_id)
            refute Repo.exists?(from cur in Cursor, where: cur.host_id == ^c.host)
            assert {:error, %{code: :unauthorized}} = EdgeSync.next(c.auth, request)
          after
            send(delivery.pid, :release_delivery)
            Task.shutdown(revoker, 5_000)
          end
        after
          send(delivery.pid, :release_delivery)
          Task.shutdown(delivery, 5_000)
        end
      end)
    end
  end

  defp wait_for_lock(_backend, 0), do: false

  defp wait_for_lock(backend, attempts) do
    case Repo.query!("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)", [
           backend
         ]).rows do
      [[true]] ->
        true

      [[false]] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp with_real_fixture(fun) do
    {:ok, pool} = Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)
    previous = Repo.put_dynamic_repo(pool)
    c = fixture()

    try do
      fun.(Map.put(c, :repo, pool))
    after
      try do
        Repo.delete_all(
          from e in Backplane.MemorySpaces.Entitlement, where: e.host_id in ^[c.host, c.owner]
        )

        Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
          Ecto.UUID.dump!(c.token)
        ])

        Repo.query!("DELETE FROM skill_host_auth_tokens WHERE id=$1", [Ecto.UUID.dump!(c.token)])

        for host <- [c.host, c.owner] do
          Repo.delete_all(
            from a in Backplane.MemorySpaces.LegacyAlias,
              where: a.alias_value == ^("host:" <> host)
          )

          Repo.query!("DELETE FROM skill_hosts WHERE id=$1", [Ecto.UUID.dump!(host)])
          space = MemorySpaces.private_host_space_id(host)
          Repo.delete_all(from s in Backplane.MemorySpaces.MemorySpace, where: s.id == ^space)
        end
      after
        Repo.put_dynamic_repo(previous)
        GenServer.stop(pool)
      end
    end
  end

  defp fixture do
    [owner, host] = for _ <- 1..2, do: insert_host!()
    {:ok, partition} = MemorySpaces.provision_private_host(owner, "shared-feed")
    {:ok, _} = MemorySpaces.provision_private_host(host, "recipient-feed")
    token = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_host_auth_tokens (id,name,token_hash,encrypted_token,inserted_at,updated_at) VALUES ($1,$2,'isolated-test',$3,now(),now())",
      [Ecto.UUID.dump!(token), token, <<1>>]
    )

    Repo.query!(
      "INSERT INTO skill_host_agent_tokens (id,host_id,auth_token_id,inserted_at,updated_at) VALUES ($1,$2,$3,now(),now())",
      Enum.map([Ecto.UUID.generate(), host, token], &Ecto.UUID.dump!/1)
    )

    auth = %{
      kind: :host_agent,
      host_id: host,
      auth_token_id: token,
      scopes: ~w(host_agent.recall host_agent.import),
      source_client_id: "feed-test"
    }

    %{owner: owner, host: host, partition: partition, token: token, auth: auth}
  end

  defp insert_host! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'fixture',now(),now())",
      [Ecto.UUID.dump!(id), id]
    )

    id
  end

  defp operator, do: %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()}

  defp grant(c, caps) do
    {:ok, access} =
      MemorySpaces.grant_host_access(operator(), c.host, c.partition, caps,
        reason: "shared feed fixture",
        expected_version: 0
      )

    access
  end

  defp offer(extended \\ true),
    do: %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => if(extended, do: ["memory_access.v1", "memory_commands.v2"], else: [])
      }
    }

  defp request(c, access),
    do: %{
      "protocol" => "host_memory.v2",
      "partition" => wire(c.partition),
      "access" => %{
        "access_id" => access.access_id,
        "authority_version" => access.authority_version
      },
      "applied_revision" => 0
    }

  defp wire(p), do: Map.new(p, fn {k, v} -> {to_string(k), v} end)

  defp ack(request, batch),
    do:
      Map.merge(request, %{
        "batch_id" => batch["batch_id"],
        "status" => "applied",
        "applied_revision" => batch["to_revision"],
        "snapshot_id" => batch["snapshot_id"],
        "next_chunk_index" =>
          if(batch["kind"] == "snapshot_chunk", do: batch["chunk_index"] + 1, else: nil),
        "chunk_hash" => batch["chunk_hash"],
        "integrity_hash" => batch["integrity_hash"]
      })

  defp seed(c) do
    {:ok, memory} =
      Backplane.Memory.Memories.remember(
        "shared source fixture",
        Map.to_list(c.partition) ++
          [host_id: c.owner, client_id: "host:" <> c.owner, agent_id: "feed-test"]
      )

    memory
  end
end
