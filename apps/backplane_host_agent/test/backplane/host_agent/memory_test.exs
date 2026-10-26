defmodule Backplane.HostAgent.MemoryTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "private",
    "namespace" => "private"
  }

  setup %{tmp_dir: dir} do
    store = start_supervised!({Store, database: Path.join(dir, "commands.db"), pool_size: 1})
    :ok = Migrator.migrate(store)
    owner = start_supervised!({Access, name: nil, store: store, now_fun: fn -> 10_000 end})

    inventory = %{
      "extensions" => ~w(memory_access.v1 memory_commands.v2),
      "default_access_id" => @id,
      "accesses" => [
        %{
          "access_id" => @id,
          "authority_version" => 1,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => ~w(read remember forget),
          "offline_read_lease_seconds" => 0
        }
      ]
    }

    :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, inventory, owner)
    {:ok, target, _} = Access.begin_request(:default, :remember, owner)
    %{store: store, owner: owner, target: target, inventory: inventory}
  end

  test "exact caller request deduplicates while changed content cannot reuse its identity", c do
    args = %{
      "content" => "durable note",
      "idempotency_key" => "one",
      "metadata" => %{"nested" => %{"b" => 2, "a" => 1}}
    }

    assert {:ok, first} = enqueue(c, args)
    assert {:ok, reused} = enqueue(c, args)
    assert reused["dedup"]
    assert Map.delete(reused, "dedup") == Map.delete(first, "dedup")
    assert {:error, :idempotency_conflict} = enqueue(c, Map.put(args, "content", "changed"))

    assert {:ok, %{rows: [%{"count" => 1}]}} =
             Store.query(c.store, "SELECT count(*) AS count FROM memory_outbox")

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT count(*) AS count FROM memories")
  end

  test "concurrent identical requests create one authority-bound durable command", c do
    tasks =
      for _ <- 1..8,
          do:
            Task.async(fn ->
              enqueue(c, %{"content" => "concurrent", "idempotency_key" => "one"})
            end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert length(Enum.uniq(Enum.map(results, fn {:ok, result} -> result["command_id"] end))) == 1

    assert {:ok,
            %{
              rows: [
                %{
                  "access_id" => @id,
                  "authority_version" => 1,
                  "target_partition" => target,
                  "request_agent_id" => "actor"
                }
              ]
            }} =
             Store.query(
               c.store,
               "SELECT access_id,authority_version,target_partition,request_agent_id FROM memory_outbox"
             )

    assert Jason.decode!(target) == @partition
  end

  test "failed durable insert releases no provisional receipt or partial command", c do
    assert {:ok, _} =
             Store.execute(
               c.store,
               "CREATE TRIGGER reject_command BEFORE INSERT ON memory_outbox BEGIN SELECT RAISE(ABORT,'forced insertion failure'); END"
             )

    assert {:error, _} = enqueue(c, %{"content" => "must roll back", "idempotency_key" => "one"})

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT count(*) AS count FROM memory_outbox")

    assert {:ok, _} = Store.execute(c.store, "DROP TRIGGER reject_command")

    assert {:ok, %{"status" => "pending"}} =
             enqueue(c, %{"content" => "must roll back", "idempotency_key" => "one"})
  end

  test "owner restart reuses durable identity and exact payload instead of a new command", c do
    args = %{"content" => "survive restart", "idempotency_key" => "restart"}
    assert {:ok, first} = enqueue(c, args)
    assert {:ok, %{rows: [before]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
    GenServer.stop(c.owner)

    owner =
      start_supervised!({Access, name: nil, store: c.store, now_fun: fn -> 10_000 end},
        id: :replacement_access
      )

    :ok = Access.install_inventory(%{id: 2, sent_at_ms: 10_000}, c.inventory, owner)
    {:ok, target, _} = Access.begin_request(:default, :remember, owner)
    assert {:ok, reused} = enqueue(%{c | owner: owner, target: target}, args)
    assert reused["command_id"] == first["command_id"]
    assert reused["dedup"]
    assert {:ok, %{rows: [^before]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
  end

  test "slots remain device-local JSON data", c do
    opts = [store: c.store, agent_id: "actor"]

    assert {:ok, _} =
             Memory.slot_write(%{"key" => "session", "value" => %{"key" => [1, true]}}, opts)

    assert {:ok, result} = Memory.slot_read(%{"key" => "session"}, opts)
    assert result["value"] == %{"key" => [1, true]}
  end

  defp enqueue(c, args),
    do:
      Access.run_local(
        c.target,
        :remember,
        &Memory.shared_enqueue(&1, "remember", args, "actor"),
        c.owner
      )
end
