defmodule Backplane.HostAgent.Memory.SupervisorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Migrator
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor

  @moduletag :tmp_dir

  defmodule CanonicalRemote do
    def call("recall", _args, _opts),
      do: {:ok, %{"results" => [%{"id" => "canonical", "content" => "online"}]}}
  end

  test "edge cannot reuse the command database", %{tmp_dir: dir} do
    path = Path.join(dir, "command.db")

    {:ok, pid} =
      MemorySupervisor.start_link(%{
        enabled: true,
        db_path: path,
        name: nil,
        store_name: :collision_command_store,
        host_sync_v2: %{
          enabled: true,
          development_plaintext: true,
          db_path: path,
          name: nil,
          store_name: :collision_edge_store
        }
      })

    refute Process.whereis(:collision_edge_store)
    assert {:ok, _} = Migrator.current_version(:collision_command_store)
    Supervisor.stop(pid)
  end

  test "edge open failure preserves command services", %{tmp_dir: dir} do
    previous_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)

    on_exit(fn ->
      if previous_runtime,
        do: Application.put_env(:backplane_host_agent, :capture_runtime, previous_runtime),
        else: Application.delete_env(:backplane_host_agent, :capture_runtime)
    end)

    {:ok, capture} =
      Backplane.HostAgent.Memory.CaptureSupervisor.start_link(%{
        enabled: true,
        name: nil,
        host_id: "host",
        db_path: Path.join(dir, "capture.db"),
        spool_name: :edge_failure_capture_spool,
        uploader_name: :edge_failure_uploader,
        recall_cache_name: :edge_failure_cache
      })

    blocked = Path.join(dir, "blocked")
    File.write!(blocked, "file")

    {:ok, pid} =
      MemorySupervisor.start_link(%{
        enabled: true,
        db_path: Path.join(dir, "command.db"),
        name: nil,
        store_name: :failure_command_store,
        host_sync_v2: %{
          enabled: true,
          development_plaintext: true,
          db_path: Path.join(blocked, "edge.db"),
          name: nil
        }
      })

    assert {:ok, _} = Migrator.current_version(:failure_command_store)
    assert is_pid(Process.whereis(:failure_command_store_syncer))
    assert is_pid(Process.whereis(:failure_command_store_pruner))
    assert Process.alive?(capture)
    assert is_pid(Process.whereis(:edge_failure_uploader))

    assert %{pending_depth: 0} =
             Backplane.HostAgent.Memory.Spool.Turso.stats(:edge_failure_capture_spool)

    assert {:ok, %{"results" => [%{"id" => "canonical"}]}} =
             Backplane.HostAgent.MemoryFacade.call("recall", %{}, %{
               agent_id: "agent",
               store: :failure_command_store,
               remote_adapter: CanonicalRemote,
               config: %{bound_scope: "proj_local"}
             })

    Supervisor.stop(pid)
    Supervisor.stop(capture)
  end

  test "edge rejection leaves command store and syncer available", %{tmp_dir: dir} do
    store = :edge_rejection_command_store

    {:ok, pid} =
      MemorySupervisor.start_link(%{
        enabled: true,
        db_path: Path.join(dir, "command.db"),
        name: nil,
        store_name: store,
        host_sync_v2: %{enabled: true, db_path: Path.join(dir, "rejected/edge.db")}
      })

    assert Process.alive?(pid)
    assert {:ok, _} = Migrator.current_version(store)
    assert is_pid(Process.whereis(:edge_rejection_command_store_syncer))
    refute File.exists?(Path.join(dir, "rejected"))

    assert Enum.any?(Supervisor.which_children(pid), fn {id, child, _, _} ->
             id == Backplane.HostAgent.Memory.Edge.Supervisor and child == :undefined
           end)

    Supervisor.stop(pid)
  end

  test "config defaults edge persistence off and parses explicit bounded opt-in", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    File.write!(path, "agent:\n  work_dir: #{dir}\n")
    {:ok, config} = Backplane.HostAgent.Config.load(path)
    assert config.memory.host_sync_v1 == %{enabled: false}
    assert config.memory.host_sync_v2.enabled == false
    assert config.memory.host_sync_v2.development_plaintext == false

    File.write!(path, """
    agent:
      work_dir: #{dir}
    memory:
      host_sync_v1:
        enabled: true
      host_sync_v2:
        enabled: true
        development_plaintext: true
        db_path: #{dir}/custom/edge.db
        max_frame_bytes: 9999999
        max_changes: 999
        sync_interval_ms: 1234
    """)

    {:ok, config} = Backplane.HostAgent.Config.load(path)
    assert config.memory.host_sync_v1.enabled

    assert config.memory.host_sync_v2 == %{
             enabled: true,
             development_plaintext: true,
             db_path: Path.join(dir, "custom/edge.db"),
             reserved_db_paths: [
               Path.join(dir, "memory/host_agent_memory.db"),
               Path.join(dir, "memory/capture_spool.db")
             ],
             max_frame_bytes: 524_288,
             max_changes: 100,
             max_items: 10_000,
             max_bytes: 64 * 1024 * 1024,
             max_items_per_partition: 5_000,
             max_age_days: 90,
             type_quotas: %{},
             sync_interval_ms: 1234
           }

    File.write!(path, """
    agent:
      work_dir: #{dir}
    memory:
      host_sync_v2:
        enabled: true
        development_plaintext: true
        db_path: #{dir}/memory/capture_spool.db
    """)

    {:ok, config} = Backplane.HostAgent.Config.load(path)
    assert config.memory.host_sync_v2.enabled

    assert Backplane.HostAgent.Memory.Edge.Protection.status(config.memory.host_sync_v2) ==
             :protection_unavailable
  end

  test "starts the store and completes migrations before returning", %{tmp_dir: tmp_dir} do
    supervisor_name = :"host_agent_memory_supervisor_#{System.unique_integer([:positive])}"
    store_name = :"host_agent_memory_supervisor_store_#{System.unique_integer([:positive])}"
    pruner_name = :"host_agent_memory_supervisor_pruner_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "memory.db")

    assert {:ok, pid} =
             MemorySupervisor.start_link(%{
               db_path: db_path,
               enabled: true,
               name: supervisor_name,
               store_name: store_name,
               pruner_name: pruner_name,
               prune_interval_ms: 60_000
             })

    latest = Migrator.latest_version()
    assert {:ok, ^latest} = Migrator.current_version(store_name)
    assert is_pid(Process.whereis(pruner_name))

    Supervisor.stop(pid)
  end
end
