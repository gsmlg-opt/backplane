defmodule Backplane.Plugins.Scheduler do
  @moduledoc "Schedules due source snapshots; at most one scheduled synchronization runs per source."
  use GenServer
  alias Backplane.Plugins

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, running) do
    now = DateTime.utc_now()

    running =
      Enum.reduce(Plugins.list_sources(), running, fn source, tasks ->
        due =
          source.enabled and
            (is_nil(source.last_attempt_at) or
               DateTime.diff(now, source.last_attempt_at) >= source.interval_seconds)

        if due and source.id not in Map.values(tasks) do
          {_pid, ref} = spawn_monitor(fn -> Plugins.sync_source(source.id) end)
          Map.put(tasks, ref, source.id)
        else
          tasks
        end
      end)

    schedule()
    {:noreply, running}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, running),
    do: {:noreply, Map.delete(running, ref)}

  defp schedule, do: Process.send_after(self(), :tick, 30_000)
end
