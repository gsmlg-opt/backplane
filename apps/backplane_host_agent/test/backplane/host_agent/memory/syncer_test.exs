defmodule Backplane.HostAgent.Memory.SyncerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Migrator, Reducer, Store, Syncer}
  alias ExTurso.Result

  @moduletag :tmp_dir

  defmodule FakeChannel do
    @moduledoc false

    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:memory_push, event, payload})

      case Process.get({__MODULE__, :reply}) do
        nil ->
          {:ok,
           %{
             "items" =>
               Enum.map(payload["items"], fn item ->
                 %{
                   "id" => item["id"],
                   "status" => "ok",
                   "canonical_id" => "remote_#{item["id"]}",
                   "error" => nil
                 }
               end)
           }}

        reply ->
          reply
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    {:ok, store: store, opts: memory_opts(store)}
  end

  test "drains pending outbox FIFO and marks ok acks done", %{store: store, opts: opts} do
    {:ok, %{"id" => first_id}} = Memory.remember(%{"content" => "first"}, opts)
    {:ok, %{"id" => second_id}} = Memory.remember(%{"content" => "second"}, opts)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               batch_size: 1
             )

    assert_receive {:memory_push, "memory_sync", %{"items" => [item]}}
    assert item["op"] == "remember"
    assert item["id"] == first_id
    assert item["content"] == "first"

    assert_outbox(store, first_id, "done", 0)
    assert_outbox(store, second_id, "pending", 0)

    assert {:ok, %Result{rows: [%{"sync_state" => "synced", "remote_id" => remote_id}]}} =
             Store.query(store, "SELECT sync_state, remote_id FROM memories WHERE id = ?", [
               first_id
             ])

    assert remote_id == "remote_#{first_id}"
  end

  test "builds remember payload from the current memory row at drain time", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "tag me", "tags" => ["old"]}, opts)

    assert {:ok, _} =
             Memory.facet_tag(
               %{"id" => id, "tags" => ["new"], "metadata" => %{"topic" => "sync"}},
               opts
             )

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_receive {:memory_push, "memory_sync", %{"items" => [item]}}
    assert item["id"] == id
    assert item["tags"] == ["new"]
    assert item["metadata"] == %{"topic" => "sync"}
  end

  test "transient channel errors return inflight rows to pending without attempts", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "retry later"}, opts)
    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, :disconnected} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "pending", 0)
  end

  test "validation errors mark rows failed and increment attempts", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "bad payload"}, opts)

    Process.put({FakeChannel, :reply}, {
      :ok,
      %{"items" => [%{"id" => id, "status" => "error", "error" => "invalid scope"}]}
    })

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "failed", 1)

    assert {:ok, %Result{rows: [%{"last_error" => "invalid scope"}]}} =
             Store.query(store, "SELECT last_error FROM memory_outbox WHERE memory_id = ?", [id])
  end

  test "forget payload includes remote_id and leaves deleted rows synced after ack", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "forget sync"}, opts)

    assert {:ok, _} =
             Store.execute(store, "UPDATE memory_outbox SET state = 'done' WHERE memory_id = ?", [
               id
             ])

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memories SET sync_state = 'synced', remote_id = ? WHERE id = ?",
               ["hub_1", id]
             )

    assert {:ok, _} = Memory.forget(%{"id" => id}, opts)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_receive {:memory_push, "memory_sync", %{"items" => [item]}}
    assert item["op"] == "forget"
    assert item["id"] == id
    assert item["remote_id"] == "hub_1"
    assert item["content_hash"] == Reducer.content_hash("forget sync")
    assert is_binary(item["deleted_at"])

    assert {:ok, %Result{rows: [%{"sync_state" => "synced", "deleted_at" => deleted_at}]}} =
             Store.query(store, "SELECT sync_state, deleted_at FROM memories WHERE id = ?", [id])

    assert is_binary(deleted_at)
  end

  test "join payload announces bound scope with fact set hash", %{store: store} do
    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO facts(id, content, content_hash, scope, tags, metadata, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 "fact_1",
                 "fact content",
                 Reducer.content_hash("fact content"),
                 "proj_local",
                 Jason.encode!(["ops"]),
                 Jason.encode!(%{"topic" => "memory"}),
                 "2026-06-17T00:00:00Z"
               ]
             )

    assert %{
             "memory" => %{
               "protocol" => "host_memory.v1",
               "scopes" => [%{"scope" => "proj_local", "fact_set_hash" => hash}]
             }
           } = Syncer.join_payload(store: store, config: %{bound_scope: "proj_local"})

    assert hash == Syncer.fact_set_hash(store, "proj_local")
    assert hash != empty_hash()
  end

  test "empty fact set hash is sha256 of canonical empty list", %{store: store} do
    assert Syncer.fact_set_hash(store, "proj_local") == empty_hash()
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_syncer_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp memory_opts(store) do
    [
      store: store,
      agent_id: "agent_1",
      config: %{bound_scope: "proj_local", tombstone_relearn: "block"}
    ]
  end

  defp assert_outbox(store, memory_id, state, attempts) do
    assert {:ok, %Result{rows: [%{"state" => ^state, "attempts" => ^attempts}]}} =
             Store.query(store, "SELECT state, attempts FROM memory_outbox WHERE memory_id = ?", [
               memory_id
             ])
  end

  defp empty_hash do
    :crypto.hash(:sha256, "[]")
    |> Base.encode16(case: :lower)
  end
end
