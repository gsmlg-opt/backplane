defmodule Backplane.HostAgent.MemoryFacadeTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{MemoryFacade, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}

  @moduletag :tmp_dir
  @access "11111111-1111-4111-8111-111111111111"
  @canonical "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "private",
    "namespace" => "private"
  }

  defmodule Channel do
    def push(observer, "memory_sync", payload) do
      send(observer, {:canonical_batch, payload})
      mode = Process.get({__MODULE__, :mode})

      if mode == :timeout do
        {:error, :timeout}
      else
        {:ok,
         %{
           "protocol" => "memory_commands.v2",
           "items" =>
             Enum.map(payload["items"], fn item ->
               item
               |> Map.take(~w(command_id access partition))
               |> Map.merge(%{
                 "status" => "committed",
                 "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                 "revision" => nil,
                 "mirror_status" => "not_eligible"
               })
             end)
         }}
      end
    end
  end

  defmodule Remote do
    def call(method, args, opts) do
      send(self(), {:canonical_read, method, args, opts})

      {:ok,
       %{
         "access" => opts[:access],
         "partition" => %{
           "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
           "scope" => "private",
           "namespace" => "private"
         },
         "result" => %{
           "results" => [%{"id" => "canonical", "content" => "canonical fact"}],
           "cursor" => "page-2"
         }
       }}
    end
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    store = start_supervised!({Store, database: Path.join(dir, "memory.db"), pool_size: 1})
    :ok = Migrator.migrate(store)
    owner = start_supervised!({Access, name: nil, store: store, now_fun: fn -> 10_000 end})
    on_exit(fn -> MemoryProxy.set_channel(nil) end)

    inventory = %{
      "extensions" => ~w(memory_access.v1 memory_commands.v2),
      "default_access_id" => @access,
      "accesses" => [
        %{
          "access_id" => @access,
          "authority_version" => 1,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => ~w(read remember forget),
          "offline_read_lease_seconds" => 0
        }
      ]
    }

    context = %{
      agent_id: "author",
      access_server: owner,
      remote_adapter: Remote,
      sync_opts: [channel: self(), channel_module: Channel]
    }

    %{store: store, owner: owner, inventory: inventory, context: context}
  end

  test "cold default commands fail closed without creating an unbound outbox row", c do
    assert {:error, :unauthorized} =
             MemoryFacade.call("remember", %{"content" => "cold"}, c.context)

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT count(*) AS count FROM memory_outbox")
  end

  test "default private and explicit writes use the same immutable canonical command path", c do
    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, c.inventory, c.owner)

    assert {:ok,
            %{
              "status" => "committed",
              "canonical_id" => @canonical,
              "id" => @canonical,
              "scope" => "private",
              "sync_state" => "synced",
              "dedup" => false
            }} =
             MemoryFacade.call("remember", %{"content" => "default note"}, c.context)

    assert_receive {:canonical_batch, %{"protocol" => "memory_commands.v2", "items" => [first]}}
    assert first["arguments"]["type"] == "episodic"
    assert first["access"] == %{"access_id" => @access, "authority_version" => 1}
    assert first["partition"] == @partition

    assert {:ok, %{"status" => "committed"}} =
             MemoryFacade.call(
               "remember",
               %{"memory_access_id" => @access, "content" => "selected note"},
               c.context
             )

    assert_receive {:canonical_batch, %{"items" => [second]}}
    assert second["arguments"]["type"] == "semantic"

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(
               c.store,
               "SELECT count(*) AS count FROM memory_outbox WHERE access_id IS NULL"
             )
  end

  test "transport retry preserves command access version partition and request key", c do
    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, c.inventory, c.owner)
    Process.put({Channel, :mode}, :timeout)
    args = %{"content" => "retry note", "idempotency_key" => "stable-request"}

    assert {:ok,
            %{
              "status" => "pending",
              "command_id" => command,
              "id" => id,
              "scope" => "private",
              "sync_state" => "pending",
              "dedup" => false
            }} =
             MemoryFacade.call("remember", args, c.context)

    assert id == command
    assert_receive {:canonical_batch, %{"items" => [first]}}
    Process.delete({Channel, :mode})

    assert {:ok, %{"status" => "committed", "command_id" => ^command, "dedup" => true}} =
             MemoryFacade.call("remember", args, c.context)

    assert_receive {:canonical_batch, %{"items" => [^first]}}

    assert {:ok, %{rows: [%{"request_key" => "stable-request", "attempts" => 1}]}} =
             Store.query(
               c.store,
               "SELECT request_key,attempts FROM memory_outbox WHERE command_id=?",
               [command]
             )
  end

  test "online default reads preserve canonical metadata with an authenticated command overlay",
       c do
    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, c.inventory, c.owner)

    assert {:ok,
            %{
              "cursor" => "page-2",
              "items" => [%{"id" => "canonical"}],
              "authority" => "canonical"
            }} =
             MemoryFacade.call("list", %{}, c.context)

    assert_received {:canonical_read, "list", %{}, opts}
    assert opts[:access] == %{"access_id" => @access, "authority_version" => 1}
    refute opts[:inject_agent_id]
  end

  test "known transport classifications do not accept authorization or arbitrary failures" do
    for reason <- [
          :timeout,
          :not_connected,
          :econnrefused,
          {:socket_error, :closed},
          {:channel_exit, :normal}
        ],
        do: assert(MemoryFacade.transport_error?(reason))

    for reason <- [:unauthorized, :partition_mismatch, :invalid_arguments, :not_found, :arbitrary],
        do: refute(MemoryFacade.transport_error?(reason))
  end
end
