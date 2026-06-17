defmodule Backplane.HostAgent.Memory.StoreTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Store
  alias ExTurso.Result

  @moduletag :tmp_dir

  test "starts an ExTurso pool with WAL and busy timeout", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)

    assert {:ok, %Result{rows: [%{"journal_mode" => mode}]}} =
             Store.query(store, "PRAGMA journal_mode")

    assert String.downcase(mode) == "wal"

    assert {:ok, %Result{rows: [busy_timeout]}} = Store.query(store, "PRAGMA busy_timeout")
    assert 5_000 in Map.values(busy_timeout)
  end

  test "wraps execute query and transaction without domain logic", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)

    assert {:ok, _} =
             Store.execute(store, "CREATE TABLE writes (id INTEGER PRIMARY KEY, note TEXT)")

    assert {:error, :rollback_check} =
             Store.transaction(store, fn conn ->
               {:ok, _} =
                 Store.execute(conn, "INSERT INTO writes(id, note) VALUES (?, ?)", [
                   1,
                   "rolled back"
                 ])

               DBConnection.rollback(conn, :rollback_check)
             end)

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM writes")
  end

  defp start_store!(tmp_dir) do
    name = :"host_agent_memory_store_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    name
  end
end
