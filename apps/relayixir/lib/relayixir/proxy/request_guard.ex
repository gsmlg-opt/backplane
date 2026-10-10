defmodule Relayixir.Proxy.RequestGuard do
  @moduledoc false
  use GenServer, restart: :temporary

  # The controller must outlive a killed Plug process, including before headers.
  # Keep an aborted controller available until Fetch's bounded request deadline
  # so a transport launched concurrently with cancellation also sees the signal.
  def start(owner, timeout) do
    with {:ok, guard} <-
           DynamicSupervisor.start_child(
             Relayixir.Proxy.RequestSupervisor,
             {__MODULE__, {owner, timeout}}
           ) do
      {:ok, guard, GenServer.call(guard, :controller)}
    end
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def track_upload(guard, upload), do: GenServer.call(guard, {:track_upload, upload})

  def release(nil), do: :ok

  def release(guard) do
    GenServer.stop(guard, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def init({owner, timeout}) do
    monitor = Process.monitor(owner)
    controller = HTTP.AbortController.new()
    Process.send_after(self(), :deadline, timeout + 1_000)
    {:ok, %{controller: controller, monitor: monitor, upload: nil}}
  end

  @impl true
  def handle_call(:controller, _from, state), do: {:reply, state.controller, state}

  def handle_call({:track_upload, upload}, _from, state) do
    {:reply, :ok, %{state | upload: upload}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{monitor: monitor} = state) do
    HTTP.AbortController.abort(state.controller)
    if state.upload, do: Process.exit(state.upload, :shutdown)
    {:noreply, %{state | upload: nil}}
  end

  def handle_info(:deadline, state) do
    HTTP.AbortController.abort(state.controller)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, state) do
    if reason != :normal, do: HTTP.AbortController.abort(state.controller)
    Agent.stop(state.controller)
  end
end
