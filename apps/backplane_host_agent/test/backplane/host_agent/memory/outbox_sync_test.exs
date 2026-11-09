defmodule Backplane.HostAgent.Memory.OutboxSyncTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Local, Migrator, OutboxSync, Store}
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor

  @moduletag :tmp_dir

  defmodule ScriptedHub do
    @moduledoc false
    use Agent

    def start_link({handler, channel}),
      do: Agent.start_link(fn -> {handler, [], channel} end, name: __MODULE__)

    # Stands in for MemoryProxy so tests do not depend on global channel state.
    def channel, do: Agent.get(__MODULE__, &elem(&1, 2))

    def set_channel(channel), do: Agent.update(__MODULE__, &put_elem(&1, 2, channel))

    def set_handler(handler), do: Agent.update(__MODULE__, &put_elem(&1, 0, handler))

    def calls, do: Agent.get(__MODULE__, fn {_, calls, _} -> Enum.reverse(calls) end)

    def tool_calls, do: Enum.filter(calls(), &match?({:call_tool, _, _}, &1))

    def call_tool(name, args), do: dispatch({:call_tool, name, args})

    def pull_memory(cursor, limit), do: dispatch({:pull_memory, cursor, limit})

    defp dispatch(call) do
      handler =
        Agent.get_and_update(__MODULE__, fn {h, calls, ch} -> {h, {h, [call | calls], ch}} end)

      handler.(call)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    start_supervised!({ScriptedHub, {&default_handler/1, self()}})

    store = start_store!(tmp_dir)
    assert :ok = Migrator.migrate(store)
    sync = start_sync!(store)
    {:ok, store: store, sync: sync}
  end

  test "flushes queued remembers in order and maps them to remote ids", %{
    store: store,
    sync: sync
  } do
    {:ok, a} = Local.queue_remember(store, %{"content" => "first"}, "host-agent:a")
    {:ok, b} = Local.queue_remember(store, %{"content" => "second"}, "host-agent:b")

    assert :ok = OutboxSync.sync_now(sync)

    assert [
             {:call_tool, "memory::remember",
              %{"content" => "first", "request_key" => "host-agent:a"}},
             {:call_tool, "memory::remember",
              %{"content" => "second", "request_key" => "host-agent:b"}}
           ] = ScriptedHub.tool_calls()

    assert {:ok, %{"local_id" => la, "sync" => "synced"}} =
             Local.get(store, "remote-host-agent:a")

    assert {:ok, %{"local_id" => lb, "sync" => "synced"}} =
             Local.get(store, "remote-host-agent:b")

    assert {la, lb} == {a["local_id"], b["local_id"]}
    assert %{"outbox_pending" => 0, "local_records" => 2} = Local.stats(store)
    assert is_binary(Local.get_state(store, "last_sync_at"))
  end

  test "a timed-out remember is resent with the same request_key and maps to the same remote id",
       %{store: store, sync: sync} do
    {:ok, rec} = Local.queue_remember(store, %{"content" => "maybe written"}, "host-agent:t")

    # The gateway writes the record but the reply times out.
    ScriptedHub.set_handler(fn
      {:call_tool, "memory::remember", _} -> {:error, :timeout}
      call -> default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)
    assert %{"outbox_pending" => 1} = Local.stats(store)
    assert [%{"attempts" => 1}] = outbox_rows(store, "SELECT attempts FROM memory_outbox")
    assert {:ok, %{"sync" => "pending"}} = Local.get(store, rec["local_id"])

    ScriptedHub.set_handler(&default_handler/1)
    assert :ok = OutboxSync.sync_now(sync)

    keys =
      for {:call_tool, "memory::remember", args} <- ScriptedHub.calls(), do: args["request_key"]

    assert keys == ["host-agent:t", "host-agent:t"]

    assert {:ok, %{"local_id" => local_id, "sync" => "synced"}} =
             Local.get(store, "remote-host-agent:t")

    assert local_id == rec["local_id"]
    assert %{"outbox_pending" => 0, "local_records" => 1} = Local.stats(store)
  end

  test "a forget of an offline-created record waits for its remember and uses the remote id",
       %{store: store, sync: sync} do
    {:ok, rec} = Local.queue_remember(store, %{"content" => "temp"}, "host-agent:f")
    {:ok, _} = Local.queue_forget(store, rec["local_id"], "wrong")

    ScriptedHub.set_handler(fn
      {:call_tool, _, _} -> {:error, :not_connected}
      call -> default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)
    assert [{:call_tool, "memory::remember", _}] = ScriptedHub.tool_calls()
    assert %{"outbox_pending" => 2} = Local.stats(store)

    ScriptedHub.set_handler(&default_handler/1)
    assert :ok = OutboxSync.sync_now(sync)

    assert [
             {:call_tool, "memory::remember", _},
             {:call_tool, "memory::remember", _},
             {:call_tool, "memory::forget", %{"id" => "remote-host-agent:f", "reason" => "wrong"}}
           ] = ScriptedHub.tool_calls()

    assert {:ok, %{"status" => "forgotten", "sync" => "synced", "local_id" => local_id}} =
             Local.get(store, "remote-host-agent:f")

    assert local_id == rec["local_id"]
    assert %{"outbox_pending" => 0} = Local.stats(store)
  end

  test "pending entries survive a supervisor restart and flush afterwards", %{tmp_dir: tmp_dir} do
    config = %{
      enabled: true,
      db_path: Path.join(tmp_dir, "restart/memory.db"),
      name: :"outbox_sync_sup_#{System.unique_integer([:positive])}",
      store_name: :"outbox_sync_sup_store_#{System.unique_integer([:positive])}",
      sync_name: :"outbox_sync_sup_sync_#{System.unique_integer([:positive])}",
      sync_interval_ms: :infinity,
      hub_proxy: ScriptedHub,
      memory_proxy: ScriptedHub
    }

    {:ok, sup} = MemorySupervisor.start_link(config)
    Process.unlink(sup)
    {:ok, _} = Local.queue_remember(config.store_name, %{"content" => "durable"}, "host-agent:r")
    :ok = Supervisor.stop(sup)

    {:ok, sup} = MemorySupervisor.start_link(config)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    assert %{"outbox_pending" => 1} = Local.stats(config.store_name)
    assert :ok = OutboxSync.sync_now(config.sync_name)

    assert [{:call_tool, "memory::remember", %{"content" => "durable"}}] =
             ScriptedHub.tool_calls()

    assert {:ok, %{"sync" => "synced"}} = Local.get(config.store_name, "remote-host-agent:r")
    assert %{"outbox_pending" => 0} = Local.stats(config.store_name)
  end

  test "pull applies a gateway forget so offline search excludes the record", %{
    store: store,
    sync: sync
  } do
    {:ok, _} = Local.upsert_remote(store, remote("r-9", "alpha beta", "active"))
    assert [%{"id" => "r-9"}] = Local.search(store, "alpha")

    ScriptedHub.set_handler(fn
      {:pull_memory, nil, 200} ->
        {:ok, %{"records" => [remote("r-9", "alpha beta", "forgotten")], "cursor" => cursor(1)}}

      call ->
        default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)

    assert Local.search(store, "alpha") == []
    assert {:ok, %{"status" => "forgotten"}} = Local.get(store, "r-9")
    assert Jason.decode!(Local.get_state(store, "pull_cursor")) == cursor(1)
  end

  test "pull pages until a short page and resumes from the saved cursor", %{
    store: store,
    sync: sync
  } do
    page = for i <- 1..200, do: remote("p-#{i}", "page item #{i}", "active")

    ScriptedHub.set_handler(fn
      {:pull_memory, nil, 200} ->
        {:ok, %{"records" => page, "cursor" => cursor(200)}}

      {:pull_memory, c, 200} when c == %{"updated_at" => "t200", "id" => "c200"} ->
        {:ok, %{"records" => [], "cursor" => c}}

      call ->
        default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)

    assert [{:pull_memory, nil, 200}, {:pull_memory, cursor(200), 200}] ==
             Enum.filter(ScriptedHub.calls(), &match?({:pull_memory, _, _}, &1))

    assert %{"local_records" => 200} = Local.stats(store)
    assert Jason.decode!(Local.get_state(store, "pull_cursor")) == cursor(200)
  end

  test "a gateway validation error fails the entry and later entries still flush", %{
    store: store,
    sync: sync
  } do
    {:ok, _} =
      Local.queue_remember(store, %{"content" => "bad", "kind" => "bogus"}, "host-agent:v1")

    {:ok, _} = Local.queue_remember(store, %{"content" => "good"}, "host-agent:v2")

    ScriptedHub.set_handler(fn
      {:call_tool, "memory::remember", %{"kind" => "bogus"}} -> {:error, "invalid kind"}
      call -> default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)

    assert {:ok, %{"sync" => "synced"}} = Local.get(store, "remote-host-agent:v2")
    assert %{"outbox_failed" => 1, "outbox_pending" => 0} = Local.stats(store)

    assert [%{"state" => "failed", "last_error" => "invalid kind"}] =
             outbox_rows(store, "SELECT state, last_error FROM memory_outbox")

    # Failed entries are not retried silently.
    assert :ok = OutboxSync.sync_now(sync)
    assert length(ScriptedHub.tool_calls()) == 2
  end

  test "pull errors are recorded in sync state", %{store: store, sync: sync} do
    ScriptedHub.set_handler(fn
      {:pull_memory, _, _} -> {:error, "invalid_cursor"}
      call -> default_handler(call)
    end)

    assert :ok = OutboxSync.sync_now(sync)
    assert Local.get_state(store, "last_error") =~ "invalid_cursor"
    assert Local.get_state(store, "last_sync_at") == nil
  end

  test "no calls are made while the channel is down", %{store: store, sync: sync} do
    ScriptedHub.set_channel(nil)
    {:ok, _} = Local.queue_remember(store, %{"content" => "offline"}, "host-agent:d")

    assert :ok = OutboxSync.sync_now(sync)

    assert ScriptedHub.calls() == []
    assert %{"outbox_pending" => 1} = Local.stats(store)
  end

  # -- helpers --

  # A gateway double that deduplicates remembers by request_key.
  defp default_handler({:call_tool, "memory::remember", args}) do
    {:ok,
     %{
       "id" => "remote-" <> args["request_key"],
       "kind" => args["kind"] || "note",
       "content" => args["content"],
       "subjects" => [],
       "tags" => [],
       "status" => "active",
       "updated_at" => "2026-11-09T00:00:00Z",
       "provenance" => %{"writer" => "agent"}
     }}
  end

  defp default_handler({:call_tool, "memory::forget", %{"id" => id, "reason" => reason}}) do
    {:ok,
     %{
       "id" => id,
       "content" => "temp",
       "subjects" => [],
       "tags" => [],
       "status" => "forgotten",
       "forgotten_reason" => reason,
       "updated_at" => "2026-11-09T00:00:01Z",
       "provenance" => %{"writer" => "agent"}
     }}
  end

  defp default_handler({:pull_memory, cursor, _limit}),
    do: {:ok, %{"records" => [], "cursor" => cursor}}

  defp remote(id, content, status) do
    %{
      "id" => id,
      "kind" => "note",
      "content" => content,
      "subjects" => [],
      "tags" => [],
      "status" => status,
      "updated_at" => "2026-11-09T00:00:00Z",
      "provenance" => %{"writer" => "agent"}
    }
  end

  defp cursor(n), do: %{"updated_at" => "t#{n}", "id" => "c#{n}"}

  defp outbox_rows(store, sql) do
    {:ok, %Turso.Result{rows: rows}} = Store.query(store, sql, [])
    rows
  end

  defp start_sync!(store) do
    name = :"outbox_sync_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OutboxSync,
       store: store,
       name: name,
       hub_proxy: ScriptedHub,
       memory_proxy: ScriptedHub,
       interval_ms: :infinity},
      id: name
    )

    name
  end

  defp start_store!(dir) do
    File.mkdir_p!(dir)
    name = :"host_agent_outbox_sync_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Store,
       database: Path.join(dir, "#{name}.db"), name: name, pool_size: 1, busy_timeout_ms: 5_000},
      id: name
    )

    name
  end
end
