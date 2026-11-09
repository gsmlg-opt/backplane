defmodule Backplane.HostAgent.Memory.LocalTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Local, Migrator, Store}
  alias Backplane.HostAgent.Memory.Migrations.{V1, V2, V3, V4, V5, V6, V7}
  alias Turso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)
    assert :ok = Migrator.migrate(store)
    {:ok, store: store}
  end

  test "V7 database migrates to V8 leaving only the new tables", %{tmp_dir: tmp_dir} do
    store = start_store!(Path.join(tmp_dir, "legacy"))

    for {mod, v} <- Enum.with_index([V1, V2, V3, V4, V5, V6, V7], 1) do
      assert {:ok, _} =
               Store.transaction(store, fn conn ->
                 Enum.each(mod.up(), fn sql -> assert {:ok, _} = Store.execute(conn, sql) end)
                 assert {:ok, _} = Store.execute(conn, "PRAGMA user_version = #{v}")
               end)
    end

    assert :ok = Migrator.migrate(store)
    assert {:ok, 8} = Migrator.current_version(store)

    assert {:ok, %Result{rows: rows}} =
             Store.query(
               store,
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '__turso_internal%' ORDER BY name"
             )

    assert Enum.map(rows, & &1["name"]) == ~w(local_records memory_outbox memory_sync_state)
  end

  test "queue_remember creates a pending record and one outbox row", %{store: store} do
    assert {:ok, rec} =
             Local.queue_remember(
               store,
               %{
                 "content" => "deploy runs on friday",
                 "kind" => "fact",
                 "subjects" => [%{"type" => "Service", "key" => "API"}],
                 "tags" => ["ops"],
                 "agent" => "a1"
               },
               "host-agent:k1"
             )

    assert rec["sync"] == "pending"
    assert rec["id"] == rec["local_id"]
    assert rec["kind"] == "fact"
    assert rec["status"] == "active"
    assert rec["subjects"] == [%{"type" => "service", "key" => "api"}]
    assert rec["provenance"]["writer"] == "agent"
    assert rec["provenance"]["agent"] == "a1"

    assert [%{"op" => "remember", "local_id" => lid, "payload" => payload}] =
             Local.pending_outbox(store, 10)

    assert lid == rec["local_id"]
    assert payload["request_key"] == "host-agent:k1"
    assert payload["content"] == "deploy runs on friday"
  end

  test "upsert_remote fills remote_id on the row with a matching request_key", %{store: store} do
    {:ok, rec} = Local.queue_remember(store, %{"content" => "x"}, "host-agent:k2")

    assert {:ok, synced} =
             Local.upsert_remote(store, remote(%{"id" => "r-1"}, "host-agent:k2"))

    assert synced["id"] == "r-1"
    assert synced["local_id"] == rec["local_id"]
    assert synced["sync"] == "synced"
    assert count(store, "local_records") == 1

    # second upsert by remote_id updates, not inserts
    assert {:ok, again} =
             Local.upsert_remote(store, remote(%{"id" => "r-1", "content" => "y"}, nil))

    assert again["content"] == "y"
    assert count(store, "local_records") == 1
  end

  test "upsert_remote inserts unknown remote records", %{store: store} do
    assert {:ok, r} = Local.upsert_remote(store, remote(%{"id" => "r-9"}, nil))
    assert r["id"] == "r-9"
    assert r["sync"] == "synced"
    assert {:ok, ^r} = Local.get(store, "r-9")
  end

  test "queue_forget by local_id and by remote_id", %{store: store} do
    {:ok, a} = Local.queue_remember(store, %{"content" => "a"}, "k-a")
    {:ok, b} = Local.queue_remember(store, %{"content" => "b"}, "k-b")
    {:ok, _} = Local.upsert_remote(store, remote(%{"id" => "r-b", "content" => "b"}, "k-b"))

    assert {:ok, fa} = Local.queue_forget(store, a["local_id"], "stale")
    assert fa["status"] == "forgotten"
    assert fa["forgotten_reason"] == "stale"

    assert {:ok, fb} = Local.queue_forget(store, "r-b", "wrong")
    assert fb["status"] == "forgotten"
    assert fb["local_id"] == b["local_id"]

    forgets = Enum.filter(Local.pending_outbox(store, 10), &(&1["op"] == "forget"))
    assert length(forgets) == 2
    assert Enum.all?(forgets, &Map.has_key?(&1["payload"], "reason"))

    assert {:error, :not_found} = Local.queue_forget(store, "nope", "x")
  end

  test "already forgotten adds no outbox row", %{store: store} do
    {:ok, a} = Local.queue_remember(store, %{"content" => "a"}, "k-a")
    assert {:ok, _} = Local.queue_forget(store, a["local_id"], "r")
    before = length(Local.pending_outbox(store, 10))
    assert {:ok, row} = Local.queue_forget(store, a["local_id"], "again")
    assert row["status"] == "forgotten"
    assert length(Local.pending_outbox(store, 10)) == before
  end

  test "search matches CJK, ANDs terms, hides forgotten unless include_inactive", %{store: store} do
    {:ok, a} = Local.queue_remember(store, %{"content" => "部署 在周五 完成"}, "k1")
    {:ok, _} = Local.queue_remember(store, %{"content" => "other thing", "kind" => "fact"}, "k2")

    assert [%{"id" => id}] = Local.search(store, "部署", %{})
    assert id == a["local_id"]

    assert [] = Local.search(store, "部署 missing", %{})
    assert [%{"kind" => "fact"}] = Local.search(store, "other", %{"kind" => "fact"})

    {:ok, _} = Local.queue_forget(store, a["local_id"], "r")
    assert [] = Local.search(store, "部署", %{})
    assert [_] = Local.search(store, "部署", %{"include_inactive" => true})
  end

  test "search filters by subject and agent; recent returns worklog only", %{store: store} do
    {:ok, _} =
      Local.queue_remember(
        store,
        %{
          "content" => "log entry",
          "kind" => "worklog",
          "agent" => "a1",
          "subjects" => [%{"type" => "repo", "key" => "bp"}]
        },
        "k1"
      )

    {:ok, _} = Local.queue_remember(store, %{"content" => "log entry two", "agent" => "a2"}, "k2")

    assert [_] = Local.search(store, "log", %{"subject" => "repo:bp"})
    assert [_] = Local.search(store, "log", %{"agent" => "a2"})
    assert [%{"kind" => "worklog"}] = Local.recent(store, %{})
  end

  test "get returns not_found", %{store: store} do
    assert {:error, :not_found} = Local.get(store, "missing")
  end

  test "complete, fail, bump_attempt, stats and state", %{store: store} do
    {:ok, a} = Local.queue_remember(store, %{"content" => "a"}, "k-a")
    {:ok, b} = Local.queue_remember(store, %{"content" => "b"}, "k-b")
    [oa, ob] = Local.pending_outbox(store, 10)

    assert %{"outbox_pending" => 2, "outbox_failed" => 0, "local_records" => 2} =
             Local.stats(store)

    assert :ok = Local.bump_attempt(store, oa["seq"], "timeout")
    assert [%{"attempts" => 1, "last_error" => "timeout"} | _] = Local.pending_outbox(store, 10)

    assert :ok = Local.complete(store, oa["seq"], remote(%{"id" => "r-a"}, "k-a"))
    assert {:ok, %{"sync" => "synced", "id" => "r-a"}} = Local.get(store, a["local_id"])

    assert :ok = Local.fail(store, ob["seq"], "invalid kind")
    assert {:ok, %{"sync" => "failed"}} = Local.get(store, b["local_id"])
    assert [] = Local.pending_outbox(store, 10)

    stats = Local.stats(store)
    assert stats["outbox_failed"] == 1
    assert stats["outbox_pending"] == 0

    assert Local.get_state(store, "last_sync_at") == nil
    assert :ok = Local.put_state(store, "last_sync_at", "2026-01-01T00:00:00Z")
    assert :ok = Local.put_state(store, "last_sync_at", "2026-01-02T00:00:00Z")
    assert Local.get_state(store, "last_sync_at") == "2026-01-02T00:00:00Z"
    assert Local.stats(store)["last_sync_at"] == "2026-01-02T00:00:00Z"
  end

  defp remote(attrs, request_key) do
    base = %{
      "id" => "r-0",
      "kind" => "note",
      "title" => nil,
      "content" => "x",
      "subjects" => [],
      "property" => nil,
      "tags" => [],
      "status" => "active",
      "superseded_by" => nil,
      "forgotten_reason" => nil,
      "observed_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-01T00:00:00Z",
      "provenance" => %{"writer" => "agent", "agent" => nil, "integration" => nil, "session" => nil}
    }

    base |> Map.merge(attrs) |> Map.put("request_key", request_key)
  end

  defp count(store, table) do
    {:ok, %Result{rows: [%{"c" => c}]}} = Store.query(store, "SELECT COUNT(*) AS c FROM #{table}")
    c
  end

  defp start_store!(dir) do
    File.mkdir_p!(dir)
    name = :"host_agent_memory_local_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Store, database: Path.join(dir, "#{name}.db"), name: name, pool_size: 1, busy_timeout_ms: 5_000},
      id: name
    )

    name
  end
end
