defmodule Backplane.HostAgent.Memory.FactsTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Facts, Migrator, Reducer, Store}
  alias ExTurso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    {:ok, store: store, opts: memory_opts(store)}
  end

  test "full fact reconcile replaces the scope idempotently and recall sees facts", %{
    store: store,
    opts: opts
  } do
    payload = %{
      "scope" => "proj_local",
      "full" => true,
      "facts" => [
        fact("fact_1", "alpha fact", tags: ["ops"]),
        fact("fact_2", "beta fact")
      ]
    }

    assert {:ok, %{"scope" => "proj_local", "count" => 2, "full" => true}} =
             Facts.apply_facts(payload, store: store)

    assert {:ok, %{"hits" => [%{"id" => "fact_1", "source" => "hub_fact"}]}} =
             Memory.recall(%{"query" => "alpha"}, opts)

    replacement = %{payload | "facts" => [fact("fact_2", "beta fact updated")]}

    assert {:ok, %{"count" => 1}} = Facts.apply_facts(replacement, store: store)
    assert {:ok, %{"hits" => []}} = Memory.recall(%{"query" => "alpha"}, opts)
    assert_count(store, "facts", 1)

    assert {:ok, %{"count" => 1}} = Facts.apply_facts(replacement, store: store)
    assert_count(store, "facts", 1)
  end

  test "incremental fact reconcile upserts without replacing other facts", %{store: store} do
    assert {:ok, %{"count" => 1}} =
             Facts.apply_facts(
               %{"scope" => "proj_local", "full" => true, "facts" => [fact("fact_1", "old")]},
               store: store
             )

    assert {:ok, %{"count" => 1, "full" => false}} =
             Facts.apply_facts(
               %{
                 "scope" => "proj_local",
                 "full" => false,
                 "facts" => [fact("fact_2", "new")]
               },
               store: store
             )

    assert_count(store, "facts", 2)

    assert {:ok, %{"count" => 1}} =
             Facts.apply_facts(
               %{
                 "scope" => "proj_local",
                 "facts" => [fact("fact_1", "updated", metadata: %{"v" => 2})]
               },
               store: store
             )

    assert {:ok, %Result{rows: [%{"content" => "updated", "metadata" => metadata}]}} =
             Store.query(store, "SELECT content, metadata FROM facts WHERE id = ?", ["fact_1"])

    assert Jason.decode!(metadata) == %{"v" => 2}
    assert_count(store, "facts", 2)
  end

  test "wipe hard-deletes local memory and facts, cancels queued outbox, and tombstones", %{
    store: store,
    opts: opts
  } do
    content = "wipe target"
    hash = Reducer.content_hash(content)

    assert {:ok, %{"id" => local_id}} = Memory.remember(%{"content" => content}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memories SET remote_id = ?, sync_state = 'synced' WHERE id = ?",
               [
                 "hub_1",
                 local_id
               ]
             )

    assert {:ok, _} =
             Facts.apply_facts(
               %{"scope" => "proj_local", "full" => false, "facts" => [fact("fact_1", content)]},
               store: store
             )

    assert {:ok,
            %{
              "directive_id" => "wipe_1",
              "items" => [%{"content_hash" => ^hash, "scope" => "proj_local", "status" => "ok"}]
            }} =
             Facts.apply_wipe(
               %{
                 "directive_id" => "wipe_1",
                 "items" => [
                   %{"remote_id" => "hub_1", "content_hash" => hash, "scope" => "proj_local"}
                 ]
               },
               store: store
             )

    assert_count(store, "memories", 0)
    assert_count(store, "facts", 0)

    assert {:ok, %Result{rows: [%{"state" => "done", "last_error" => "wiped"}]}} =
             Store.query(
               store,
               "SELECT state, last_error FROM memory_outbox WHERE memory_id = ?",
               [
                 local_id
               ]
             )

    assert {:error, :wiped} = Memory.remember(%{"content" => content}, opts)
  end

  test "wipe by content hash is idempotent and cancels inflight rows", %{store: store, opts: opts} do
    content = "hash wipe target"
    hash = Reducer.content_hash(content)
    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => content}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'inflight' WHERE memory_id = ?",
               [id]
             )

    payload = %{
      "directive_id" => "wipe_hash",
      "items" => [%{"content_hash" => hash, "scope" => "proj_local"}]
    }

    assert {:ok, %{"items" => [%{"status" => "ok"}]}} = Facts.apply_wipe(payload, store: store)
    assert {:ok, %{"items" => [%{"status" => "ok"}]}} = Facts.apply_wipe(payload, store: store)

    assert_count(store, "memories", 0)

    assert {:ok, %Result{rows: [%{"state" => "done", "last_error" => "wiped"}]}} =
             Store.query(
               store,
               "SELECT state, last_error FROM memory_outbox WHERE memory_id = ?",
               [id]
             )
  end

  defp fact(id, content, opts \\ []) do
    %{
      "id" => id,
      "content" => content,
      "content_hash" => Reducer.content_hash(content),
      "tags" => Keyword.get(opts, :tags, []),
      "metadata" => Keyword.get(opts, :metadata, %{}),
      "updated_at" => Keyword.get(opts, :updated_at, "2026-06-17T00:00:00Z")
    }
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_facts_#{System.unique_integer([:positive])}"
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

  defp assert_count(store, table, expected) do
    assert {:ok, %Result{rows: [%{"count" => ^expected}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM #{table}")
  end
end
