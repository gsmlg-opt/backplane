defmodule Backplane.HostAgent.Memory.Edge.SupervisorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Backplane.HostAgent.Memory.Edge.{Supervisor, Migrator}
  @moduletag :tmp_dir

  test "parent shutdown terminates supervisor and pool normally", %{tmp_dir: dir} do
    config = %{
      enabled: true,
      development_plaintext: true,
      db_path: Path.join(dir, "shutdown.db"),
      name: nil,
      store_name: :edge_shutdown_pool
    }

    {:ok, parent} = Elixir.Supervisor.start_link([{Supervisor, config}], strategy: :one_for_one)
    [{Supervisor, edge, _, _}] = Elixir.Supervisor.which_children(parent)
    edge_monitor = Process.monitor(edge)
    pool_monitor = Process.monitor(Process.whereis(:edge_shutdown_pool))
    stop = Task.async(fn -> Elixir.Supervisor.stop(parent) end)
    assert_receive {:DOWN, ^edge_monitor, :process, ^edge, :shutdown}, 1_000
    assert_receive {:DOWN, ^pool_monitor, :process, _, :shutdown}, 1_000
    assert :ok = Task.await(stop)
  end

  test "storage and migration startup failures do not exit the caller", %{tmp_dir: dir} do
    invalid_dir = Path.join(dir, "file")
    File.write!(invalid_dir, "not a directory")

    config = %{
      enabled: true,
      development_plaintext: true,
      db_path: Path.join(invalid_dir, "edge.db"),
      name: nil
    }

    assert Supervisor.start_link(config) == :ignore

    db = Path.join(dir, "invalid.db")
    {:ok, store} = Backplane.HostAgent.Memory.Edge.Store.start_link(database: db, config: config)

    {:ok, _} =
      Backplane.HostAgent.Memory.Edge.Store.execute(store, "CREATE TABLE edge_memories (id TEXT)")

    GenServer.stop(store)
    assert Supervisor.start_link(%{config | db_path: db}) == :ignore
    assert Process.alive?(self())
  end

  test "unavailable supervisor has diagnostics without any process or directory", %{tmp_dir: dir} do
    config = %{enabled: true, db_path: Path.join(dir, "absent/edge.db")}
    assert Supervisor.start_link(config) == :ignore
    assert Supervisor.status(config) == :protection_unavailable
    assert Supervisor.status(%{}) == :disabled
    refute File.exists?(Path.join(dir, "absent"))
  end

  test "development startup warns and completes migration", %{tmp_dir: dir} do
    config = %{
      enabled: true,
      development_plaintext: true,
      db_path: Path.join(dir, "edge.db"),
      name: nil,
      store_name: :edge_supervisor_test_store
    }

    assert capture_log(fn ->
             {:ok, pid} = Supervisor.start_link(config)
             assert {:ok, 1} = Migrator.current_version(config.store_name)
             Elixir.Supervisor.stop(pid)
           end) =~ "plaintext_development"
  end
end
