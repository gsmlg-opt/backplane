defmodule Backplane.HostAgent.Memory.SupervisorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Migrator
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor

  @moduletag :tmp_dir

  test "config drops removed host_sync keys", %{tmp_dir: dir} do
    path = Path.join(dir, "removed-config.yaml")

    File.write!(path, """
    agent:
      work_dir: #{dir}
    memory:
      host_sync:
        enabled: true
      host_sync_v1:
        enabled: true
    """)

    assert {:ok, config} = Backplane.HostAgent.Config.load(path)
    refute Map.has_key?(config.memory, :host_sync)
    refute Map.has_key?(config.memory, :host_sync_v1)
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

    assert Enum.sort(child_ids -- [Migrator]) ==
             [Backplane.HostAgent.Memory.OutboxSync, Backplane.HostAgent.Memory.Store]

    Supervisor.stop(pid)
  end
end
