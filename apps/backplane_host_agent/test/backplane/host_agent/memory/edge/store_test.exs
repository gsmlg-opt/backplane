defmodule Backplane.HostAgent.Memory.Edge.StoreTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory.Edge.Store
  @moduletag :tmp_dir

  test "rejected and disabled opens create no directory", %{tmp_dir: dir} do
    path = Path.join(dir, "absent/edge.db")
    assert :ignore = Store.start_link(database: path, config: %{})
    assert :ignore = Store.start_link(database: path, config: %{enabled: true})

    assert :ignore =
             Store.start_link(
               database: path,
               protection: :plaintext_development,
               mode: :plaintext_development,
               config: %{enabled: true, env: :dev}
             )

    refute File.exists?(Path.dirname(path))
  end

  test "explicit development pool persists across restarts", %{tmp_dir: dir} do
    opts = [
      database: Path.join(dir, "edge/store.db"),
      config: %{enabled: true, development_plaintext: true}
    ]

    {:ok, store} = Store.start_link(opts)
    assert {:ok, _} = Store.execute(store, "CREATE TABLE marker (value TEXT)")

    assert {:ok, :ok} =
             Store.transaction(store, fn conn ->
               {:ok, _} = Store.execute(conn, "INSERT INTO marker VALUES (?)", ["durable"])
               :ok
             end)

    GenServer.stop(store)
    {:ok, store} = Store.start_link(opts)
    assert {:ok, %{rows: [%{"value" => "durable"}]}} = Store.query(store, "SELECT * FROM marker")
    GenServer.stop(store)
  end
end
