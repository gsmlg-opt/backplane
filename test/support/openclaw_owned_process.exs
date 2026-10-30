defmodule Backplane.OpenClawOwnedProcess do
  @moduledoc false

  def stop(pid, stop_fun \\ &GenServer.stop/3, timeout \\ 10_000) when is_pid(pid) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)

    try do
      if Process.alive?(pid) do
        try do
          stop_fun.(pid, :normal, timeout)
        catch
          :exit, {:noproc, {GenServer, :stop, [^pid, :normal, ^timeout]}} -> :ok
        end
      end

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        timeout -> exit(:owned_process_shutdown_unconfirmed)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end
