defmodule Backplane.HostAgent.Memory.PluginHTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}
  alias Backplane.HostAgent.{MemoryProxy, MemoryRouter}
  alias Turso.Result

  @moduletag :tmp_dir
  @integrations_root Path.expand("../../../../../../integrations/memory", __DIR__)

  defmodule EmptyCanonicalChannel do
    def push(_channel, "memory_call", payload, _timeout) do
      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "access" => payload["access"],
           "partition" => partition(),
           "result" => %{"results" => []}
         }
       }}
    end

    def push(_channel, "memory_sync", _payload), do: {:error, :not_connected}

    def partition,
      do: %{
        "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "scope" => "host-bound",
        "namespace" => "private"
      }
  end

  defmodule NoChannel do
    def channel, do: nil
  end

  defmodule Facade do
    def call(method, args, context),
      do:
        Backplane.HostAgent.MemoryFacade.call(
          method,
          args,
          Map.put(context, :sync_opts, channel_provider: NoChannel)
        )
  end

  defmodule RouterPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_private(:backplane_memory_facade, Facade)
      |> MemoryRouter.call(MemoryRouter.init([]))
    end
  end

  setup %{tmp_dir: tmp_dir} do
    keys = [:memory_store, :memory_config, :channel_module]
    previous = Map.new(keys, &{&1, Application.fetch_env(:backplane_host_agent, &1)})
    name = :"memory_plugin_http_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Store, database: Path.join(tmp_dir, "memory.db"), name: name, pool_size: 1}
    )

    assert :ok = Migrator.migrate(name)
    owner = start_supervised!({Access, name: nil, store: name, now_fun: fn -> 10_000 end})
    Process.register(owner, Access)

    inventory = %{
      "extensions" => ~w(memory_access.v1 memory_commands.v2),
      "default_access_id" => "11111111-1111-4111-8111-111111111111",
      "accesses" => [
        %{
          "access_id" => "11111111-1111-4111-8111-111111111111",
          "authority_version" => 1,
          "status" => "active",
          "partition" => EmptyCanonicalChannel.partition(),
          "capabilities" => ~w(read remember forget),
          "offline_read_lease_seconds" => 0
        }
      ]
    }

    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, inventory, owner)

    MemoryProxy.set_channel(nil)
    Application.put_env(:backplane_host_agent, :memory_store, name)
    Application.put_env(:backplane_host_agent, :memory_config, %{bound_scope: "host-bound"})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:backplane_host_agent, key, value)
        {key, :error} -> Application.delete_env(:backplane_host_agent, key)
      end)

      MemoryProxy.set_channel(nil)
    end)

    server =
      start_supervised!({Gaoxy.HTTP, plug: {RouterPlug, []}, ip: {127, 0, 0, 1}, port: 0})

    %{local: {:ok, {{127, 0, 0, 1}, port}}} = Gaoxy.info(server, :http)

    {:ok,
     owner: owner,
     store: name,
     inventory: inventory,
     base_url: "http://127.0.0.1:#{port}",
     tmp_dir: tmp_dir}
  end

  test "cold or fenced authority cannot stage an unbound offline command", %{
    owner: owner,
    store: store,
    base_url: base_url
  } do
    assert :ok = Access.fence(:all, :connection_rejected, 1, owner)

    assert {:ok, %{body: %{"ok" => false, "error" => "unauthorized"}}} =
             Req.post(base_url <> "/memory/hermes/call/remember", json: %{"content" => "cold"})

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT count(*) AS count FROM memory_outbox")
  end

  test "Hermes exposes pending commands while the online canonical list is still empty", %{
    store: store,
    inventory: inventory,
    base_url: base_url,
    tmp_dir: tmp_dir
  } do
    assert :ok =
             MemoryProxy.set_connection(
               %{
                 channel: self(),
                 memory_generation: %{id: 1, sent_at_ms: 10_000},
                 memory: Map.put(inventory, "selected", "host_memory.v2")
               },
               %{memory: %{bound_scope: "host-bound"}}
             )

    Application.put_env(:backplane_host_agent, :channel_module, EmptyCanonicalChannel)
    assert_roundtrip!(base_url, store, tmp_dir, "online")
  end

  test "negotiated scope mismatch rejects reads and writes before local persistence", %{
    store: store,
    base_url: base_url
  } do
    Application.put_env(:backplane_host_agent, :channel_module, EmptyCanonicalChannel)

    MemoryProxy.set_connection(
      %{
        channel: self(),
        memory: %{
          "selected" => "host_memory.v2",
          "default_access_id" => "default",
          "accesses" => [
            %{
              "access_id" => "default",
              "partition" => %{"scope" => "mac-mini", "namespace" => "private"}
            }
          ]
        }
      },
      %{memory: %{enabled: true, bound_scope: "host-bound"}}
    )

    for {method, body} <- [{"list", %{}}, {"remember", %{"content" => "must not persist"}}] do
      assert {:ok, %{status: 400, body: %{"ok" => false, "error" => "memory_scope_mismatch"}}} =
               Req.post(base_url <> "/memory/hermes/call/" <> method, json: body)
    end

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memories")

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox")
  end

  defp assert_roundtrip!(base_url, store, tmp_dir, mode) do
    python = System.find_executable("python3") || flunk("python3 is required")
    script = Path.expand("../../../support/hermes_provisional_http.py", __DIR__)

    {output, status} =
      System.cmd(
        python,
        [
          script,
          "--provider",
          Path.join([@integrations_root, "hermes", "__init__.py"]),
          "--base-url",
          base_url,
          "--home",
          Path.join(tmp_dir, "hermes-profile"),
          "--mode",
          mode
        ],
        stderr_to_stdout: true,
        env: [
          {"PYTHONDONTWRITEBYTECODE", "1"},
          {"BACKPLANE_MEMORY_URL", nil},
          {"BACKPLANE_MEMORY_AGENT_ID", nil},
          {"BACKPLANE_MEMORY_ACCESS_ID", nil}
        ]
      )

    assert status == 0, output
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert %{
             "id" => id,
             "session_id" => session_id,
             "mode" => ^mode,
             "worker_stopped" => true
           } = result

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT count(*) AS count FROM memories")

    assert {:ok, %Result{rows: [remember, forget]}} =
             Store.query(
               store,
               "SELECT op,command_id,access_id,payload,state FROM memory_outbox ORDER BY seq"
             )

    assert remember["command_id"] == id
    assert remember["op"] == "remember"
    assert forget["op"] == "forget"
    assert Enum.all?([remember, forget], &(&1["state"] in ~w(pending retry_wait)))
    assert remember["access_id"] == forget["access_id"]
    args = Jason.decode!(remember["payload"])["arguments"]
    assert args["session_id"] == session_id
    assert args["agent_id"] == "hermes"

    assert Jason.decode!(forget["payload"])["arguments"] == %{
             "id" => id,
             "remember_command_id" => id
           }
  end
end
