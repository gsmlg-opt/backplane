defmodule Backplane.HostAgent.Memory.PluginHTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.{MemoryProxy, MemoryRouter}
  alias Turso.Result

  @moduletag :tmp_dir
  @integrations_root Path.expand("../../../../../../integrations/memory", __DIR__)

  defmodule EmptyCanonicalChannel do
    def push(_channel, "memory_call", _payload, _timeout) do
      {:ok, %{"ok" => true, "result" => %{"results" => []}}}
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
      start_supervised!({Gaoxy.HTTP, plug: {MemoryRouter, []}, ip: {127, 0, 0, 1}, port: 0})

    %{local: {:ok, {{127, 0, 0, 1}, port}}} = Gaoxy.info(server, :http)
    {:ok, store: name, base_url: "http://127.0.0.1:#{port}", tmp_dir: tmp_dir}
  end

  test "tools-only Hermes keeps offline writes provisional and excludes unsupported context", %{
    store: store,
    base_url: base_url,
    tmp_dir: tmp_dir
  } do
    assert_roundtrip!(base_url, store, tmp_dir, "offline")
  end

  test "Hermes exposes pending commands while the online canonical list is still empty", %{
    store: store,
    base_url: base_url,
    tmp_dir: tmp_dir
  } do
    MemoryProxy.set_channel(self())
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
          "selected" => "host_memory.v1",
          "memory_partition" => %{"scope" => "mac-mini", "namespace" => "private"}
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

    assert {:ok,
            %Result{
              rows: [
                %{
                  "id" => ^id,
                  "scope" => "host-bound",
                  "agent_id" => "hermes",
                  "session_id" => ^session_id,
                  "sync_state" => "pending",
                  "remote_id" => nil
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT id, scope, agent_id, session_id, sync_state, remote_id FROM memories WHERE deleted_at IS NOT NULL"
             )

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memories WHERE deleted_at IS NULL")

    assert {:ok,
            %Result{
              rows: [
                %{"op" => "remember", "memory_id" => ^id, "state" => "pending"},
                %{"op" => "forget", "memory_id" => ^id, "state" => "pending"}
              ]
            }} =
             Store.query(store, "SELECT op, memory_id, state FROM memory_outbox ORDER BY seq")
  end
end
