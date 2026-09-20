defmodule Backplane.HostAgent.Memory.SyncerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Migrator, Reducer, Store, Syncer}
  alias Turso.Result

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

        reply when is_function(reply, 1) ->
          reply.(payload)

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

  test "transient channel errors move rows to retry wait with an attempt", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "retry later"}, opts)
    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, :disconnected} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "retry_wait", 1)
  end

  test "retries only due rows with bounded deterministic backoff and dead-letters at max attempts",
       %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "retry"}, opts)
    now = "2026-06-17T00:00:00Z"
    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, :disconnected} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               now_fun: fn -> now end,
               jitter_fun: fn -> 0.5 end,
               max_attempts: 2
             )

    assert {:ok,
            %Result{
              rows: [%{"state" => "retry_wait", "next_attempt_at" => "2026-06-17T00:00:01.000Z"}]
            }} =
             Store.query(
               store,
               "SELECT state, next_attempt_at FROM memory_outbox WHERE memory_id = ?",
               [id]
             )

    assert {:ok, %{"drained" => 0}} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               now_fun: fn -> now end,
               jitter_fun: fn -> 0.5 end,
               max_attempts: 2
             )

    due = "2026-06-17T00:00:01Z"

    assert {:error, :disconnected} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               now_fun: fn -> due end,
               jitter_fun: fn -> 0.5 end,
               max_attempts: 2
             )

    assert_outbox(store, id, "dead_letter", 2)
  end

  test "clamps configured sync batches to 50 items", %{store: store, opts: opts} do
    Enum.each(1..51, fn index ->
      assert {:ok, _} = Memory.remember(%{"content" => "item #{index}"}, opts)
    end)

    assert {:ok, %{"drained" => 50}} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               batch_size: 10_000
             )

    assert_receive {:memory_push, "memory_sync", %{"items" => items}}
    assert length(items) == 50
  end

  test "does not send a memory_sync payload over 512 KiB", %{store: store, opts: opts} do
    assert {:ok, %{"id" => id}} =
             Memory.remember(%{"content" => String.duplicate("x", 512 * 1024)}, opts)

    assert {:ok, %{"drained" => 0}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    refute_receive {:memory_push, "memory_sync", _payload}
    assert_outbox(store, id, "pending", 0)
  end

  test "start schedules stranded inflight rows for retry", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "claimed before crash"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'inflight' WHERE memory_id = ?",
               [
                 id
               ]
             )

    {:ok, pid} = Syncer.start_link(store: store, channel: self(), interval_ms: 0)
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert_outbox(store, id, "retry_wait", 1)
  end

  test "start dead-letters stranded rows at their final attempt", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "final retry"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'inflight', attempts = 1 WHERE memory_id = ?",
               [id]
             )

    {:ok, pid} = Syncer.start_link(store: store, channel: self(), interval_ms: 0, max_attempts: 2)
    GenServer.stop(pid)

    assert_outbox(store, id, "dead_letter", 2)
  end

  test "malformed acknowledgement retries claimed rows without crashing", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "malformed"}, opts)
    Process.put({FakeChannel, :reply}, {:ok, %{"items" => ["not an ack"]}})

    assert {:error, :invalid_ack} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "retry_wait", 1)
  end

  test "returns a storage error when a claimed retry transition is rejected", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "trigger"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "CREATE TRIGGER reject_retry BEFORE UPDATE OF state ON memory_outbox WHEN NEW.state = 'retry_wait' BEGIN SELECT RAISE(ABORT, 'retry blocked'); END"
             )

    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, {:storage_error, _reason}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "inflight", 0)
  end

  test "missing memory rows are dead-lettered while the rest of the batch drains", %{
    store: store,
    opts: opts
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, state, inserted_at, updated_at)
               VALUES ('remember', 'missing_memory', 'pending', ?, ?)
               """,
               [now, now]
             )

    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "still syncs"}, opts)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_receive {:memory_push, "memory_sync", %{"items" => [%{"id" => ^id}]}}

    assert {:ok,
            %Result{rows: [%{"state" => "dead_letter", "attempts" => 1, "last_error" => error}]}} =
             Store.query(
               store,
               "SELECT state, attempts, last_error FROM memory_outbox WHERE memory_id = 'missing_memory'"
             )

    assert error =~ "memory row not found"
    assert_outbox(store, id, "done", 0)
  end

  test "validation errors dead-letter rows", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "bad payload"}, opts)

    Process.put({FakeChannel, :reply}, {
      :ok,
      %{"items" => [%{"id" => id, "status" => "error", "error" => "invalid scope"}]}
    })

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "dead_letter", 1)

    assert {:ok, %Result{rows: [%{"last_error" => "invalid scope"}]}} =
             Store.query(store, "SELECT last_error FROM memory_outbox WHERE memory_id = ?", [id])
  end

  test "every item error is permanent under the v1 wire", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "bad content"}, opts)

    Process.put(
      {FakeChannel, :reply},
      {:ok,
       %{
         "items" => [
           %{
             "id" => id,
             "status" => "error",
             "error" => "content is required and must be a string"
           }
         ]
       }}
    )

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_outbox(store, id, "dead_letter", 1)
  end

  test "matches acknowledgements in order when remember and forget share an id", %{
    store: store,
    opts: opts
  } do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "ordered"}, opts)
    assert {:ok, _} = Memory.forget(%{"id" => id}, opts)

    assert {:ok, %{"drained" => 2}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert_receive {:memory_push, "memory_sync",
                    %{
                      "items" => [
                        %{"op" => "remember", "id" => ^id},
                        %{"op" => "forget", "id" => ^id}
                      ]
                    }}

    assert {:ok, %Result{rows: [%{"count" => 2}]}} =
             Store.query(
               store,
               "SELECT COUNT(*) AS count FROM memory_outbox WHERE state = 'done'"
             )
  end

  test "does not resurrect a wiped row after delayed acknowledgement", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "wiped before ack"}, opts)

    Process.put({FakeChannel, :reply}, fn payload ->
      assert {:ok, _} =
               Store.execute(
                 store,
                 "UPDATE memory_outbox SET state = 'done', last_error = 'wiped' WHERE memory_id = ?",
                 [id]
               )

      {:ok,
       %{
         "items" => [
           %{"id" => hd(payload["items"])["id"], "status" => "ok", "canonical_id" => "hub"}
         ]
       }}
    end)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: FakeChannel)

    assert {:ok, %Result{rows: [%{"sync_state" => "pending"}]}} =
             Store.query(store, "SELECT sync_state FROM memories WHERE id = ?", [id])
  end

  test "caps high-attempt jittered retry delay", %{store: store, opts: opts} do
    {:ok, %{"id" => id}} = Memory.remember(%{"content" => "cap"}, opts)

    assert {:ok, _} =
             Store.execute(store, "UPDATE memory_outbox SET attempts = 20 WHERE memory_id = ?", [
               id
             ])

    now = "2026-06-17T00:00:00Z"
    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, :disconnected} =
             Syncer.drain_once(
               store: store,
               channel: self(),
               channel_module: FakeChannel,
               now_fun: fn -> now end,
               jitter_fun: fn -> 1.0 end,
               max_attempts: 50
             )

    assert {:ok, %Result{rows: [%{"next_attempt_at" => "2026-06-17T00:05:00.000Z"}]}} =
             Store.query(store, "SELECT next_attempt_at FROM memory_outbox WHERE memory_id = ?", [
               id
             ])
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
