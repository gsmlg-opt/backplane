ExUnit.start()
Code.require_file("support/openclaw_owned_process.exs", __DIR__)

defmodule Backplane.OpenClawOwnedProcessTest do
  use ExUnit.Case, async: true
  alias Backplane.OpenClawOwnedProcess

  test "a child exiting between liveness observation and stop still has exact DOWN proof" do
    {:ok, pid} = Agent.start_link(fn -> nil end)
    monitor = Process.monitor(pid)

    stop = fn target, reason, timeout ->
      :ok = GenServer.stop(target, reason, timeout)
      GenServer.stop(target, reason, timeout)
    end

    assert :ok = OpenClawOwnedProcess.stop(pid, stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute Process.alive?(pid)
  end

  test "normal and already gone children are both confirmed stopped" do
    {:ok, pid} = Agent.start_link(fn -> nil end)
    assert :ok = OpenClawOwnedProcess.stop(pid)
    refute Process.alive?(pid)

    assert :ok =
             OpenClawOwnedProcess.stop(pid, fn _, _, _ ->
               flunk("already gone child stopped again")
             end)
  end

  test "unrelated stop failures are not swallowed" do
    {:ok, pid} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert catch_exit(OpenClawOwnedProcess.stop(pid, fn _, _, _ -> exit(:unexpected) end)) ==
             :unexpected

    assert Process.alive?(pid)
  end

  test "a stop function returning success without terminating the exact process cannot pass" do
    {:ok, pid} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert catch_exit(OpenClawOwnedProcess.stop(pid, fn _, _, _ -> :ok end, 0)) ==
             :owned_process_shutdown_unconfirmed

    assert Process.alive?(pid)
  end
end
