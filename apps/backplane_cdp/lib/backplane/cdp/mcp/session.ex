defmodule Backplane.CDP.MCP.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Backplane.CDP
  @idle_timeout :timer.minutes(30)

  def start_link({port, _} = key) do
    GenServer.start_link(__MODULE__, port, name: {:via, Registry, {CDP.Registry, key}})
  end

  def call(pid, name, args) do
    GenServer.call(pid, {:tool, name, args}, :infinity)
  catch
    :exit, {:noproc, _} ->
      {:error, "Chrome DevTools session expired"}

    :exit, {reason, _} when reason in [:normal, :shutdown] ->
      {:error, "Chrome DevTools session closed"}
  end

  @impl true
  def init(port) do
    {:ok,
     %{
       port: port,
       idle_deadline: now() + @idle_timeout,
       pages: %{},
       selected: nil,
       next_id: 1,
       contexts: %{},
       snapshots: %{},
       observers: %{},
       casts: %{},
       trace: nil
     }, @idle_timeout}
  end

  @impl true
  def handle_call({:tool, name, args}, _from, state) do
    state = %{state | casts: Map.filter(state.casts, fn {pid, _} -> Process.alive?(pid) end)}

    state =
      case state.trace do
        {pid, _} -> if Process.alive?(pid), do: state, else: %{state | trace: nil}
        nil -> state
      end

    {status, result, new_state} = CDP.MCP.dispatch(name, args, state)
    {:reply, {status, result}, %{new_state | idle_deadline: now() + @idle_timeout}, @idle_timeout}
  end

  @impl true
  def handle_info({:refresh_logpoints, observer}, state) do
    if now() >= state.idle_deadline do
      {:stop, :normal, state}
    else
      if observer in Map.values(state.observers), do: CDP.MCP.Logpoints.refresh(observer)
      {:noreply, state, max(0, state.idle_deadline - now())}
    end
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
  defp now, do: System.monotonic_time(:millisecond)
end
