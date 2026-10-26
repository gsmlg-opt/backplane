defmodule Backplane.HostAgent.Memory.SyncerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Memory, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store, Syncer}

  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @canonical "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "private",
    "namespace" => "private"
  }

  defmodule Channel do
    def push(observer, "memory_sync", payload) do
      send(observer, {:batch, payload})

      case Process.get({__MODULE__, :mode}) do
        :timeout ->
          {:error, :timeout}

        mode ->
          {:ok,
           %{
             "protocol" => "memory_commands.v2",
             "items" =>
               Enum.map(payload["items"], fn item ->
                 Map.take(item, ~w(command_id access partition))
                 |> Map.merge(%{
                   "status" => "committed",
                   "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                   "revision" => if(mode == :not_eligible, do: nil, else: 7)
                 })
                 |> then(fn ack ->
                   if mode == :not_eligible,
                     do: Map.put(ack, "mirror_status", "not_eligible"),
                     else: ack
                 end)
                 |> then(fn ack ->
                   if mode == :invalid_ack, do: Map.delete(ack, "revision"), else: ack
                 end)
               end)
           }}
      end
    end
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    store = start_supervised!({Store, database: Path.join(dir, "memory.db"), pool_size: 1})
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

    on_exit(fn -> MemoryProxy.set_channel(nil) end)

    opts = [
      store: store,
      access_server: owner,
      channel: self(),
      channel_module: Channel,
      now_fun: fn -> "2026-10-26T00:00:00Z" end
    ]

    %{store: store, owner: owner, inventory: inventory, opts: opts}
  end

  test "unavailable access cannot select the retired uploader", c do
    assert {:ok, _} =
             Store.execute(
               c.store,
               "INSERT INTO memory_outbox(op,memory_id,state,inserted_at,updated_at,migration_reason) VALUES ('remember','old-id','dead_letter','old','old','needs_authority_mapping')"
             )

    assert {:ok, %{"drained" => 0, "status" => "awaiting_authority"}} = Syncer.drain_once(c.opts)
    refute_receive {:batch, _}

    assert {:ok, %{rows: [%{"state" => "dead_letter", "attempts" => 0}]}} =
             Store.query(c.store, "SELECT state,attempts FROM memory_outbox")
  end

  test "edge-ineligible success settles once with its canonical ID and explicit no-mirror ACK",
       c do
    install(c)
    receipt = enqueue(c, "remember", %{"content" => "working note", "type" => "working"})
    Process.put({Channel, :mode}, :not_eligible)

    assert {:ok, %{"drained" => 1, "protocol" => "memory_commands.v2"}} =
             Syncer.drain_once(c.opts)

    assert {:ok, %{"status" => "committed", "canonical_id" => @canonical, "revision" => nil}} =
             receipt(c, receipt["command_id"])

    assert {:ok, %{"drained" => 0}} = Syncer.drain_once(c.opts)
  end

  test "missing revision without an explicit ineligible ACK fails closed", c do
    install(c)
    queued = enqueue(c, "remember", %{"content" => "invalid ack"})
    Process.put({Channel, :mode}, :invalid_ack)
    assert {:error, :invalid_ack} = Syncer.drain_once(c.opts)

    assert {:ok, %{rows: [%{"state" => "dead_letter", "ack_canonical_id" => nil}]}} =
             Store.query(
               c.store,
               "SELECT state,ack_canonical_id FROM memory_outbox WHERE command_id=?",
               [queued["command_id"]]
             )
  end

  test "a pending forget follows the exact remembered command without cancelling a possibly committed write",
       c do
    install(c)
    first = enqueue(c, "remember", %{"content" => "ordered note"})
    forget = enqueue(c, "forget", %{"id" => first["command_id"]})
    assert {:ok, %{"drained" => 2}} = Syncer.drain_once(c.opts)
    assert_receive {:batch, %{"items" => [remember, forgotten]}}
    assert remember["command_id"] == first["command_id"]
    assert forgotten["command_id"] == forget["command_id"]

    assert forgotten["arguments"] == %{
             "id" => first["command_id"],
             "remember_command_id" => first["command_id"]
           }
  end

  test "a forget cannot overtake a still inflight remember", c do
    install(c)
    first = enqueue(c, "remember", %{"content" => "inflight note"})

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='inflight',updated_at='2026-10-26T00:00:00Z' WHERE command_id=?",
               [first["command_id"]]
             )

    enqueue(c, "forget", %{"id" => first["command_id"]})
    assert {:ok, %{"drained" => 0}} = Syncer.drain_once(c.opts)
    refute_receive {:batch, _}
  end

  test "command identity is immutable while settlement metadata remains writable", c do
    install(c)

    first =
      enqueue(c, "remember", %{"content" => "immutable note", "idempotency_key" => "request"})

    assert {:error, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET authority_version=2 WHERE command_id=?",
               [first["command_id"]]
             )

    assert {:error, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET request_key='other' WHERE command_id=?",
               [first["command_id"]]
             )

    assert {:ok, %{"drained" => 1}} = Syncer.drain_once(c.opts)
  end

  defp install(c),
    do: Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, c.inventory, c.owner)

  defp enqueue(c, operation, args) do
    {:ok, target, _ticket} =
      Access.begin_request(:default, String.to_existing_atom(operation), c.owner)

    {:ok, receipt} =
      Access.run_local(
        target,
        String.to_existing_atom(operation),
        &Memory.shared_enqueue(&1, operation, args, "author"),
        c.owner
      )

    receipt
  end

  defp receipt(c, id) do
    {:ok, target, _ticket} = Access.begin_request(:default, :remember, c.owner)
    Access.run_local(target, :remember, &Memory.shared_receipt(&1, id), c.owner)
  end
end
