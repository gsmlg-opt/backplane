defmodule Backplane.AgentRuntime.CodexCodeModeOSCleanupTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Error

  test "timing out CPU-bound JavaScript terminates the actual Deno process" do
    assert match?({:unix, :linux}, :os.type()), "OS cleanup regression requires Linux"
    deno = System.find_executable("deno")
    assert is_binary(deno), "real Deno is required"
    registry = start_supervised!(ResourceRegistry)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        CodeMode.execute(registry, "cpu", "while (true) {}",
          deno_path: deno,
          timeout: 500,
          dispatcher: fn _, _ -> {:ok, nil} end
        )
      end)

    {:ok, workers} = ResourceRegistry.worker_supervisor(registry)
    worker = await_worker(workers, System.monotonic_time(:millisecond) + 2_000)
    {:os_pid, os_pid} = :sys.get_state(worker).port |> Port.info(:os_pid)

    on_exit(fn ->
      if running?(os_pid), do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    end)

    assert {:error, %Error{class: :timeout}} = Task.await(task, 5_000)
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_stopped(os_pid, deadline)
  end

  defp await_worker(supervisor, deadline) do
    case DynamicSupervisor.which_children(supervisor) do
      [{_, pid, _, _}] ->
        pid

      [] ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          5 -> :ok
        end

        await_worker(supervisor, deadline)
    end
  end

  defp await_stopped(pid, deadline) do
    if running?(pid) do
      assert System.monotonic_time(:millisecond) < deadline,
             "Deno OS process survived worker termination"

      receive do
      after
        5 -> :ok
      end

      await_stopped(pid, deadline)
    end
  end

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not Regex.match?(~r/\) [ZX] /, stat)
      {:error, :enoent} -> false
    end
  end
end
