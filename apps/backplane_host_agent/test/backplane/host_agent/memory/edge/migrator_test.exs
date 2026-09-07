defmodule Backplane.HostAgent.Memory.Edge.MigratorTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory.Edge.{Store, Migrator}
  @moduletag :tmp_dir

  test "does not accept or migrate a foreign database at any user version", %{tmp_dir: dir} do
    for {version, table} <- [{0, "facts"}, {1, "commands"}, {2, "capture_event_spool"}] do
      {:ok, store} =
        Store.start_link(
          database: Path.join(dir, "foreign-#{version}.db"),
          config: %{enabled: true, development_plaintext: true}
        )

      {:ok, _} = Store.execute(store, "CREATE TABLE #{table} (content TEXT)")
      {:ok, _} = Store.execute(store, "INSERT INTO #{table} VALUES ('keep')")
      {:ok, _} = Store.execute(store, "PRAGMA user_version = #{version}")
      assert {:error, :invalid_edge_schema} = Migrator.migrate(store)

      assert {:ok, %{rows: [%{"content" => "keep"}]}} =
               Store.query(store, "SELECT * FROM #{table}")

      assert {:ok, ^version} = Migrator.current_version(store)
      GenServer.stop(store)
    end
  end

  test "separate schema migrates idempotently and retains contentless tombstones", %{tmp_dir: dir} do
    opts = [
      database: Path.join(dir, "edge.db"),
      config: %{enabled: true, development_plaintext: true}
    ]

    {:ok, store} = Store.start_link(opts)
    assert :ok = Migrator.migrate(store)
    assert {:ok, 1} = Migrator.current_version(store)

    assert {:ok, _} =
             Store.execute(store, """
             INSERT INTO edge_memories
               (memory_space_id, scope, namespace, generation, canonical_id, lifecycle_state, server_revision)
               VALUES ('space', 'scope', 'ns', 'generation', 'id', 'deleted', 7)
             """)

    assert {:ok, %{rows: [%{"content" => nil, "server_revision" => 7}]}} =
             Store.query(store, "SELECT content, server_revision FROM edge_memories")

    assert {:ok, %{rows: rows}} =
             Store.query(store, "SELECT name FROM sqlite_master WHERE type = 'table'")

    assert Enum.sort(Enum.map(rows, & &1["name"])) ==
             ["edge_memories", "edge_partitions", "edge_snapshot_chunks"]

    GenServer.stop(store)
    {:ok, store} = Store.start_link(opts)
    assert :ok = Migrator.migrate(store)

    assert {:ok, %{rows: [%{"server_revision" => 7}]}} =
             Store.query(store, "SELECT server_revision FROM edge_memories")

    GenServer.stop(store)
  end
end
