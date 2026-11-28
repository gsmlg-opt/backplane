defmodule Backplane.Diagnostics.Analyses.Runner do
  @moduledoc false

  use GenServer

  alias Backplane.Diagnostics.Analyses

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{opts: opts, interval: Keyword.get(opts, :interval_ms, 2_000)}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    quietly(fn -> Analyses.run_once(state.opts) end)
    {:noreply, schedule(state)}
  end

  defp quietly(fun) do
    fun.()
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> :temporarily_unavailable
  end

  defp schedule(state) do
    Process.send_after(self(), :poll, state.interval)
    state
  end
end
