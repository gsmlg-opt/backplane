defmodule Backplane.HostAgent.Worker do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    {:ok, %{last_sync: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {:reply, {:error, :not_configured}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end
end
