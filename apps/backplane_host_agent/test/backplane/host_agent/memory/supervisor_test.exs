defmodule Backplane.HostAgent.Memory.SupervisorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Migrator
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor

  @moduletag :tmp_dir

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
