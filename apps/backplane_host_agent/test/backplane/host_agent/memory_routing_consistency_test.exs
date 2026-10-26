defmodule Backplane.HostAgent.MemoryRoutingConsistencyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Backplane.HostAgent.{MemoryFacade, MemoryProxy, MemoryRouter}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store, Syncer}
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @canonical "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "private",
    "namespace" => "private"
  }

  defmodule Facade do
    def call(method, args, context),
      do:
        MemoryFacade.call(
          method,
          args,
          Map.merge(context, %{
            access_server: Process.get(:routing_owner),
            sync_opts: [channel: nil]
          })
        )
  end

  defmodule Channel do
    def push(observer, "memory_sync", batch) do
      send(observer, {:uploaded, batch})

      {:ok,
       %{
         "protocol" => "memory_commands.v2",
         "items" =>
           Enum.map(batch["items"], fn item ->
             Map.take(item, ~w(command_id access partition))
             |> Map.merge(%{
               "status" => "committed",
               "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
               "revision" => 7
             })
           end)
       }}
    end
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    store = start_supervised!({Store, database: Path.join(dir, "commands.db"), pool_size: 1})
    :ok = Migrator.migrate(store)
    owner = start_supervised!({Access, name: nil, store: store, now_fun: fn -> 10_000 end})

    :ok =
      Access.install_inventory(
        %{id: 1, sent_at_ms: 10_000},
        %{
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
        },
        owner
      )

    Process.put(:routing_owner, owner)
    previous = Application.get_env(:backplane_host_agent, :local_services)

    Application.put_env(:backplane_host_agent, :local_services, [
      Backplane.HostAgent.Services.Memory
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_host_agent, :local_services, previous),
        else: Application.delete_env(:backplane_host_agent, :local_services)

      MemoryProxy.set_channel(nil)
    end)

    %{store: store, owner: owner}
  end

  test "default HTTP and MCP writes deduplicate into the same v2 command", c do
    args = %{"content" => "same logical write", "idempotency_key" => "one"}

    assert %{"ok" => true, "result" => %{"command_id" => id, "status" => "pending"}} =
             request("/memory/actor/call/remember", args)

    mcp =
      request("/memory/actor/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "memory::remember", "arguments" => args}
      })

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = mcp
    assert Jason.decode!(text)["command_id"] == id

    assert {:ok, %{rows: [%{"access_id" => @id, "payload" => payload}]}} =
             Store.query(c.store, "SELECT access_id,payload FROM memory_outbox")

    command = Jason.decode!(payload)
    assert command["arguments"]["type"] == "episodic"
    assert command["access"] == %{"access_id" => @id, "authority_version" => 1}
    assert command["partition"] == @partition

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(
               store: c.store,
               access_server: c.owner,
               channel: self(),
               channel_module: Channel
             )

    assert_receive {:uploaded, %{"protocol" => "memory_commands.v2", "items" => [^command]}}

    assert %{
             "ok" => true,
             "result" => %{
               "command_id" => ^id,
               "status" => "committed",
               "canonical_id" => @canonical
             }
           } = request("/memory/actor/call/remember", args)
  end

  test "default and explicit HTTP requests cannot forge partition ownership", _c do
    for args <- [
          %{"content" => "spoofed", "memory_space_id" => @partition["memory_space_id"]},
          %{"content" => "spoofed", "memory_access_id" => @id, "namespace" => "private"}
        ] do
      assert %{"ok" => false, "error" => "invalid_request"} =
               request("/memory/actor/call/remember", args)
    end
  end

  test "cold authority never falls back to historical local private cache", c do
    GenServer.stop(c.owner)
    owner = start_supervised!({Access, name: nil, store: c.store}, id: :cold_access)
    Process.put(:routing_owner, owner)

    assert %{"ok" => false, "error" => "unauthorized"} =
             request("/memory/actor/call/remember", %{"content" => "cold"})

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT count(*) AS count FROM memory_outbox")
  end

  defp request(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_private(:backplane_memory_facade, Facade)
    |> MemoryRouter.call(MemoryRouter.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end
end
