defmodule Backplane.Memory.SharedCommandsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Memory.{Authorization, Memories, Service, SharedCommands}

  setup do
    fixture()
  end

  defp fixture do
    [owner, host] = for _ <- 1..2, do: insert_host!()
    {:ok, partition} = MemorySpaces.provision_private_host(owner, "shared_target")
    {:ok, _} = MemorySpaces.provision_private_host(host, "recipient_private")
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
      source_client_id: "shared-client"
    }

    %{owner: owner, host: host, token: token, partition: partition, auth: auth}
  end

  test "remember-only settles once with recipient provenance and a content-free receipt", c do
    access = grant(c, [:remember])

    command =
      command(c, access, "remember", %{"content" => "shared synthetic note", "type" => "episodic"})

    assert {:ok, %{status: :committed, canonical_id: id, revision: revision} = ack} =
             SharedCommands.settle(c.auth, command)

    assert is_integer(revision) and revision > 0
    assert {:ok, memory} = Memories.get(id, c.partition)
    assert memory.host_id == c.host
    assert memory.client_id == "host:" <> c.host
    assert memory.source_client_id == "shared-client"
    assert memory.memory_space_id == c.partition.memory_space_id
    refute Map.has_key?(ack, :content)

    assert {:ok, %{status: :duplicate, canonical_id: ^id, revision: ^revision}} =
             SharedCommands.settle(c.auth, command)

    assert Memories.count([], c.partition) == 1

    assert {:error, :unauthorized} =
             Service.call_shared("memory::list", %{}, c.auth, claim(access))
  end

  test "delete-only tombstones a foreign-source canonical ID without read", c do
    memory = seed(c, c.owner, "canonical delete fixture")
    access = grant(c, [:forget])
    command = command(c, access, "forget", %{"id" => memory.id})
    assert {:ok, %{status: :committed, canonical_id: id}} = SharedCommands.settle(c.auth, command)
    assert id == memory.id
    assert {:error, :not_found} = Memories.get(id, c.partition)

    row =
      Repo.one!(
        from m in "bpm_memories",
          where: m.id == type(^id, :binary_id),
          select: %{host: m.host_id, state: m.lifecycle_state}
      )

    assert row == %{host: c.owner, state: "tombstoned"}

    assert {:ok, %{status: :rejected, code: :not_found}} =
             SharedCommands.settle(
               c.auth,
               command(c, access, "forget", %{"id" => Ecto.UUID.generate()})
             )
  end

  test "same command ID cannot change payload, operation, version or target", c do
    access = grant(c, [:remember, :forget])
    command = command(c, access, "remember", %{"content" => "stable command"})
    assert {:ok, %{status: :committed}} = SharedCommands.settle(c.auth, command)

    for changed <- [
          put_in(command, ["arguments", "content"], "changed"),
          Map.put(command, "op", "forget"),
          put_in(command, ["access", "authority_version"], 2),
          put_in(command, ["partition", "scope"], "elsewhere")
        ] do
      assert {:error, :idempotency_conflict} = SharedCommands.settle(c.auth, changed)
    end
  end

  test "committed lost ACK can reconcile after revoke but not after credential removal", c do
    access = grant(c, [:remember])
    command = command(c, access, "remember", %{"content" => "lost acknowledgement"})
    assert {:ok, %{status: :committed, canonical_id: id}} = SharedCommands.settle(c.auth, command)

    assert {:ok, _} =
             MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "test revoke")

    assert {:ok, %{status: :duplicate, canonical_id: ^id}} =
             SharedCommands.settle(c.auth, command)

    Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
      Ecto.UUID.dump!(c.token)
    ])

    assert {:error, :unauthorized} = SharedCommands.settle(c.auth, command)
  end

  test "old-version rejected commands remain rejected after regrant", c do
    access = grant(c, [:remember])
    command = command(c, access, "remember", %{"content" => "withdrawn queued note"})
    assert {:ok, _} = MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "withdraw")

    assert {:ok, %{status: :rejected, code: :unauthorized}} =
             SharedCommands.settle(c.auth, command)

    assert {:ok, current} =
             MemorySpaces.grant_host_access(operator(), c.host, c.partition, [:remember],
               reason: "regrant",
               expected_version: 2
             )

    assert current.authority_version == 3

    assert {:ok, %{status: :rejected, code: :unauthorized}} =
             SharedCommands.settle(c.auth, command)

    assert Memories.count([], c.partition) == 0

    assert {:ok, %{status: :committed}} =
             SharedCommands.settle(
               c.auth,
               command(c, current, "remember", %{"content" => "fresh note"})
             )
  end

  test "foreign and malformed authority creates no receipts", c do
    access = grant(c, [:remember])

    for changed <- [
          put_in(
            command(c, access, "remember", %{"content" => "denied"}),
            ["access", "access_id"],
            Ecto.UUID.generate()
          ),
          Map.put(command(c, access, "remember", %{"content" => "denied"}), "host_id", c.owner)
        ] do
      assert {:error, _} = SharedCommands.settle(c.auth, changed)
    end

    assert Repo.aggregate("bpm_memory_access_commands", :count) == 0
  end

  test "credential scopes intersect grants and callback rechecks real assignment", c do
    access = grant(c, [:read, :deliver, :remember, :forget])

    assert {:ok, actor, descriptor} =
             Authorization.authorize_access(c.auth, {:access_id, access.access_id}, :read)

    assert descriptor.access_id == access.access_id
    assert actor.credential_id == c.token

    assert {:error, :unauthorized} =
             Authorization.authorize_access(
               %{c.auth | scopes: ["host_agent.recall"]},
               {:access_id, access.access_id},
               :remember
             )

    assert {:error, :unauthorized} =
             Authorization.authorize_access(
               %{c.auth | kind: :open},
               {:access_id, access.access_id},
               :read
             )

    Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
      Ecto.UUID.dump!(c.token)
    ])

    assert {:error, :unauthorized} =
             MemorySpaces.with_host_access(
               actor,
               {:access_id, access.access_id},
               :read,
               1,
               fn _ -> flunk("removed token admitted") end
             )
  end

  test "shared list and stats select exact target across source identities", c do
    first = seed(c, c.owner, "owner visible")
    second = seed(c, c.host, "recipient visible")
    seed(%{c | partition: %{c.partition | namespace: "other"}}, c.owner, "namespace sentinel")
    access = grant(c, [:read])

    assert {:ok, %{partition: partition, result: %{results: rows}}} =
             Service.call_shared("memory::list", %{}, c.auth, claim(access))

    assert partition == c.partition
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new([first.id, second.id])

    assert {:ok, %{result: %{stats: [%{memory_type: "semantic", count: 2}]}}} =
             Service.call_shared("memory::stats", %{}, c.auth, claim(access))

    assert {:error, :partition_mismatch} =
             Service.call_shared("memory::list", %{"scope" => "global"}, c.auth, claim(access))

    assert {:error, :invalid_request} =
             Service.call_shared("memory::list", %{"host_id" => c.owner}, c.auth, claim(access))

    assert {:error, :invalid_request} =
             Service.call_shared("memory::forget", %{"id" => first.id}, c.auth, claim(access))
  end

  test "configured recall V2 retains candidate sources and records requesting actor", c do
    memory = seed(c, c.owner, "quartz shared recall fixture")
    access = grant(c, [:read])

    settings = %{
      "memory.pipeline.enabled" => true,
      "memory.recall_v2.enabled" => true,
      "memory.recall_trace_enabled" => true,
      "memory.recall_channel_weights" => %{"fts" => 1, "vector" => 0, "graph" => 0}
    }

    previous = Map.new(settings, fn {key, _} -> {key, :ets.lookup(:backplane_settings, key)} end)
    Enum.each(settings, fn entry -> :ets.insert(:backplane_settings, entry) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        Enum.each(rows, &:ets.insert(:backplane_settings, &1))
      end)
    end)

    assert {:ok, %{result: %{results: rows, recall_run_id: run_id}}} =
             Service.call_shared("memory::recall", %{"query" => "quartz"}, c.auth, claim(access))

    assert Enum.any?(rows, &(&1.id == memory.id))
    assert {:ok, source} = Memories.get(memory.id, c.partition)
    assert source.host_id == c.owner
    assert source.client_id == "host:" <> c.owner
    run = Repo.get!(Backplane.Memory.Recall.Run, run_id)
    assert run.query_plan["requesting_actor"]["host_id"] == c.host
    assert run.query_plan["requesting_actor"]["credential_id"] == c.token
    actor_partition = Map.merge(c.partition, %{host_id: c.host, client_id: "host:" <> c.host})
    assert {:ok, _, [trace]} = Backplane.Memory.Recall.Store.get(run_id, actor_partition)
    assert trace.source_refs != []
    assert trace.candidate_id == memory.id
  end

  test "cross-source identical content does not impersonate the original author", c do
    original = seed(c, c.owner, "identical source content")
    access = grant(c, [:remember])

    assert {:ok, %{canonical_id: id}} =
             SharedCommands.settle(
               c.auth,
               command(c, access, "remember", %{
                 "content" => original.content,
                 "agent_id" => "shared-test"
               })
             )

    refute id == original.id
    assert {:ok, written} = Memories.get(id, c.partition)
    assert written.host_id == c.host
  end

  test "cross-source forget invalidates every private request mapping and keeps retry tombstoned",
       c do
    opts =
      Map.to_list(c.partition) ++
        [
          host_id: c.owner,
          client_id: "host:" <> c.owner,
          agent_id: "private-source",
          idempotency_scope: "host-memory.v1:" <> c.owner,
          idempotency_key: "private-local"
        ]

    {:ok, memory} = Memories.remember("private retry governed fixture", opts)
    access = grant(c, [:forget])

    assert {:ok, %{status: :committed}} =
             SharedCommands.settle(c.auth, command(c, access, "forget", %{"id" => memory.id}))

    assert %{rows: [[source, "private-local"]]} =
             Repo.query!(
               "SELECT host_id,local_id FROM bpm_host_memory_revocations WHERE memory_id=$1",
               [Ecto.UUID.dump!(memory.id)]
             )

    assert source == c.owner
    assert {:ok, retry} = Memories.remember(memory.content, opts)
    assert retry.id == memory.id
    assert retry.deleted_at
    assert {:error, :not_found} = Memories.get(memory.id, c.partition)
  end

  test "receipt storage failure rolls back the canonical mutation", c do
    access = grant(c, [:remember])
    command = command(c, access, "remember", %{"content" => "atomic receipt fixture"})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            "ALTER TABLE bpm_memory_access_commands ADD CONSTRAINT shared_test_receipt_failure CHECK (status <> 'committed')"
          )

          SharedCommands.settle(c.auth, command)
        end,
        mode: :savepoint
      )
    end

    assert Memories.count([], c.partition) == 0
    assert Repo.aggregate("bpm_memory_access_commands", :count) == 0
  end

  test "active newer authority permanently rejects the captured old version", c do
    access = grant(c, [:remember])
    command = command(c, access, "remember", %{"content" => "old generation"})

    assert {:ok, _} =
             MemorySpaces.change_host_access(
               operator(),
               access.access_id,
               1,
               %{capabilities: [:remember, :forget]},
               "new generation"
             )

    assert {:ok, %{status: :rejected, code: :authority_changed}} =
             SharedCommands.settle(c.auth, command)

    assert {:ok, %{status: :rejected, code: :authority_changed}} =
             SharedCommands.settle(c.auth, command)

    assert Memories.count([], c.partition) == 0
  end

  test "shared facets commit with remember and invalid facets have no canonical effect", c do
    dimension = "shared-facet-#{System.unique_integer([:positive])}"

    Repo.insert!(%Backplane.Memory.Facets.Dimension{
      name: dimension,
      created_at: DateTime.utc_now()
    })

    access = grant(c, [:remember])
    facets = [%{"dimension" => dimension, "value" => "decision"}]

    assert {:ok, %{canonical_id: id}} =
             SharedCommands.settle(
               c.auth,
               command(c, access, "remember", %{"content" => "facet fixture", "facets" => facets})
             )

    assert [^id] = Backplane.Memory.Facets.query(facets)

    assert {:error, :invalid_request} =
             SharedCommands.settle(
               c.auth,
               command(c, access, "remember", %{
                 "content" => "invalid facet fixture",
                 "facets" => [%{"dimension" => "unknown-shared-dimension", "value" => "denied"}]
               })
             )

    assert Memories.count([], c.partition) == 1
  end

  test "remember-only cannot change facets on a reused same-source candidate", c do
    dimensions = for _ <- 1..2, do: "shared-facet-#{System.unique_integer([:positive])}"

    for dimension <- dimensions do
      Repo.insert!(%Backplane.Memory.Facets.Dimension{
        name: dimension,
        created_at: DateTime.utc_now()
      })
    end

    [existing_dimension, new_dimension] = dimensions
    access = grant(c, [:remember])
    facets = [%{"dimension" => existing_dimension, "value" => "original"}]
    arguments = %{"content" => "same-source facet fixture", "facets" => facets}
    original = command(c, access, "remember", arguments)

    assert {:ok, %{status: :committed, canonical_id: id}} =
             SharedCommands.settle(c.auth, original)

    assert {:ok, %{status: :duplicate, canonical_id: ^id}} =
             SharedCommands.settle(c.auth, original)

    {:ok, original_memory} = Memories.get(id, c.partition)
    original_audit = Backplane.Memory.Audit.list()
    original_revision_count = Repo.aggregate("bpm_memory_changes", :count)

    for requested <- [
          [%{"dimension" => existing_dimension, "value" => "changed"}],
          [%{"dimension" => new_dimension, "value" => "added"}],
          facets
        ] do
      assert {:error, :invalid_request} =
               SharedCommands.settle(
                 c.auth,
                 command(c, access, "remember", %{arguments | "facets" => requested})
               )

      assert Repo.aggregate("bpm_memory_remember_requests", :count) == 1
      assert Repo.aggregate("bpm_memory_evidence", :count) == 1
      assert Repo.aggregate("bpm_memory_access_commands", :count) == 1
      assert Memories.count([], c.partition) == 1
      assert {:ok, ^original_memory} = Memories.get(id, c.partition)
      assert Backplane.Memory.Audit.list() == original_audit
      assert Repo.aggregate("bpm_memory_changes", :count) == original_revision_count
      assert [^id] = Backplane.Memory.Facets.query(facets)

      assert [] =
               Backplane.Memory.Facets.query([
                 %{"dimension" => new_dimension, "value" => "added"}
               ])
    end

    assert {:ok, %{status: :committed, canonical_id: ^id}} =
             SharedCommands.settle(
               c.auth,
               command(c, access, "remember", %{arguments | "facets" => []})
             )

    assert [^id] = Backplane.Memory.Facets.query(facets)
    assert Memories.count([], c.partition) == 1
  end

  test "shared recall discards retrieval if authority or credential changes before release" do
    settings = %{
      "memory.pipeline.enabled" => true,
      "memory.recall_v2.enabled" => true,
      "memory.recall_trace_enabled" => true,
      "memory.recall_channel_weights" => %{"fts" => 1, "vector" => 0, "graph" => 0}
    }

    previous = Map.new(settings, fn {key, _} -> {key, :ets.lookup(:backplane_settings, key)} end)
    Enum.each(settings, &:ets.insert(:backplane_settings, &1))

    on_exit(fn ->
      Enum.each(previous, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        Enum.each(rows, &:ets.insert(:backplane_settings, &1))
      end)
    end)

    for mode <- [:version, :credential] do
      c = fixture()
      seed(c, c.owner, "fenced quartz content")
      access = grant(c, [:read])
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:backplane, :memory, :recall, :stage],
        fn _, _, metadata, _ ->
          if metadata[:stage] == :pipeline and metadata[:status] == :ok and
               metadata[:memory_space_id] == c.partition.memory_space_id do
            result =
              case mode do
                :version ->
                  MemorySpaces.change_host_access(
                    operator(),
                    access.access_id,
                    1,
                    %{capabilities: [:read, :remember]},
                    "recheck race"
                  )

                :credential ->
                  Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
                    Ecto.UUID.dump!(c.token)
                  ])
              end

            send(parent, {:changed_before_release, result})
          end
        end,
        nil
      )

      try do
        expected = if mode == :version, do: :authority_changed, else: :unauthorized

        assert {:error, ^expected} =
                 Service.call_shared(
                   "memory::recall",
                   %{"query" => "quartz"},
                   c.auth,
                   claim(access)
                 )

        assert_receive {:changed_before_release, _}
      after
        :telemetry.detach(handler)
      end
    end
  end

  test "settlement holds authority until the outer transaction ends and rolls back without effect" do
    with_real_fixture(fn c ->
      access = grant(c, [:remember])
      envelope = command(c, access, "remember", %{"content" => "serialized shared mutation"})
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:backplane, :memory, :access, :start],
        fn _, _, metadata, _ ->
          if metadata[:action] == "remember" and self() != parent do
            send(parent, {:mutation_locked, self()})

            receive do
              :release_mutation -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

      mutator =
        Task.async(fn ->
          Repo.put_dynamic_repo(c.repo)

          Repo.transaction(fn ->
            assert {:ok, %{status: :committed} = ack} = SharedCommands.settle(c.auth, envelope)
            send(parent, {:settled_before_rollback, ack})
            Repo.rollback(:race_cleanup)
          end)
        end)

      try do
        assert_receive {:mutation_locked, mutator_pid}, 2_000

        revoker =
          Task.async(fn ->
            Repo.put_dynamic_repo(c.repo)

            Repo.transaction(fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:revoke_backend, backend})
              MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "race revoke")
            end)
          end)

        try do
          assert_receive {:revoke_backend, backend}, 2_000
          assert wait_for_lock(backend, 100)
          send(mutator_pid, :release_mutation)
          assert_receive {:settled_before_rollback, %{canonical_id: id}}, 5_000
          assert {:error, :race_cleanup} = Task.await(mutator, 5_000)

          assert {:ok, {:ok, %{status: :revoked, authority_version: 2}}} =
                   Task.await(revoker, 5_000)

          assert {:error, :not_found} = Memories.get(id, c.partition)
          assert Repo.aggregate("bpm_memory_access_commands", :count) == 0

          assert {:error, :unauthorized} =
                   Authorization.authorize_access(
                     c.auth,
                     {:access_id, access.access_id},
                     :remember
                   )
        after
          send(mutator.pid, :release_mutation)
          Task.shutdown(revoker, 5_000)
        end
      after
        send(mutator.pid, :release_mutation)
        Task.shutdown(mutator, 5_000)
        :telemetry.detach(handler)
      end
    end)
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
        end

        for host <- [c.host, c.owner] do
          space = MemorySpaces.private_host_space_id(host)
          Repo.delete_all(from s in Backplane.MemorySpaces.MemorySpace, where: s.id == ^space)
        end
      after
        Repo.put_dynamic_repo(previous)
        GenServer.stop(pool)
      end
    end
  end

  defp seed(c, source, content) do
    {:ok, memory} =
      Memories.remember(
        content,
        Map.to_list(c.partition) ++
          [host_id: source, client_id: "host:" <> source, agent_id: "shared-test"]
      )

    memory
  end

  defp grant(c, caps) do
    {:ok, access} =
      MemorySpaces.grant_host_access(operator(), c.host, c.partition, caps,
        reason: "shared test",
        expected_version: 0
      )

    access
  end

  defp claim(access), do: Map.take(access, [:access_id, :authority_version])

  defp command(c, access, op, args),
    do: %{
      "command_id" => Ecto.UUID.generate(),
      "op" => op,
      "access" => %{
        "access_id" => access.access_id,
        "authority_version" => access.authority_version
      },
      "partition" => Map.new(c.partition, fn {k, v} -> {to_string(k), v} end),
      "arguments" => args
    }

  defp operator, do: %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

  defp insert_host! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'shared_test',now(),now())",
      [Ecto.UUID.dump!(id), "shared-#{id}"]
    )

    id
  end
end
