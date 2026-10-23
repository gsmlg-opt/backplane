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
    {:ok, store: name, base_url: "http://127.0.0.1:#{port}"}
  end

  test "Hermes writes, reads, recalls, injects and deletes through the actual host HTTP API", %{
    store: store,
    base_url: base_url
  } do
    assert_roundtrip!(base_url, store)
  end

  test "Hermes exposes pending commands while the online canonical list is still empty", %{
    store: store,
    base_url: base_url
  } do
    MemoryProxy.set_channel(self())
    Application.put_env(:backplane_host_agent, :channel_module, EmptyCanonicalChannel)
    assert_roundtrip!(base_url, store)
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

  defp assert_roundtrip!(base_url, store) do
    python = System.find_executable("python3") || flunk("python3 is required")
    script = Path.join([@integrations_root, "hermes", "smoke_test.py"])

    {output, status} =
      System.cmd(
        python,
        [script, "--base-url", base_url, "--agent-id", "hermes", "--cwd", "/Users/gao/.dotfiles"],
        stderr_to_stdout: true,
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
      )

    assert status == 0, output
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result == %{
             "write" => true,
             "readback" => true,
             "recall" => true,
             "prompt" => true,
             "scope_rejected" => true,
             "delete" => true
           }

    assert {:ok, %Result{rows: [%{"scope" => "host-bound", "agent_id" => "hermes"}]}} =
             Store.query(
               store,
               "SELECT scope, agent_id FROM memories WHERE deleted_at IS NOT NULL"
             )

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memories WHERE deleted_at IS NULL")
  end
end
