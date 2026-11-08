defmodule Backplane.HostAgent.Memory.SupervisorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Migrator
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor

  @moduletag :tmp_dir

  test "config defaults edge persistence off and parses explicit bounded opt-in", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    File.write!(path, "agent:\n  work_dir: #{dir}\n")
    {:ok, config} = Backplane.HostAgent.Config.load(path)
    refute Map.has_key?(config.memory, :host_sync_v1)
    assert config.memory.host_sync.enabled == false
    assert config.memory.host_sync.development_plaintext == false

    File.write!(path, """
    agent:
      work_dir: #{dir}
    memory:
      host_sync:
        enabled: true
        development_plaintext: true
        db_path: #{dir}/custom/edge.db
        max_frame_bytes: 9999999
        max_changes: 999
        sync_interval_ms: 1234
    """)

    {:ok, config} = Backplane.HostAgent.Config.load(path)

    assert config.memory.host_sync == %{
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
      host_sync:
        enabled: true
        development_plaintext: true
        db_path: #{dir}/memory/capture_spool.db
    """)

    {:ok, config} = Backplane.HostAgent.Config.load(path)
    assert config.memory.host_sync.enabled
  end

  test "removed versioned host-sync keys do not enable or migrate persistence", %{tmp_dir: dir} do
    path = Path.join(dir, "removed-config.yaml")

    File.write!(path, """
    agent:
      work_dir: #{dir}
    memory:
      host_sync_v1:
        enabled: true
      host_sync_v2:
        enabled: true
        development_plaintext: true
    """)

    assert {:ok, config} = Backplane.HostAgent.Config.load(path)
    refute config.memory.host_sync.enabled
    refute config.memory.host_sync.development_plaintext
    refute Map.has_key?(config.memory, :host_sync_v1)
    refute Map.has_key?(config.memory, :host_sync_v2)
  end

  test "starts the store and completes migrations before returning", %{tmp_dir: tmp_dir} do
    supervisor_name = :"host_agent_memory_supervisor_#{System.unique_integer([:positive])}"
    store_name = :"host_agent_memory_supervisor_store_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "memory.db")

    assert {:ok, pid} =
             MemorySupervisor.start_link(%{
               db_path: db_path,
               enabled: true,
               name: supervisor_name,
               store_name: store_name,
               prune_interval_ms: 60_000
             })

    latest = Migrator.latest_version()
    assert {:ok, ^latest} = Migrator.current_version(store_name)

    child_ids = pid |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert child_ids -- [Migrator] == [Backplane.HostAgent.Memory.Store]

    Supervisor.stop(pid)
  end
end
