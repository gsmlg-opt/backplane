defmodule Backplane.Memory.ReplayNotifier do
  @moduledoc "Commit-ordered, content-free replay invalidations."
  use GenServer
  @channel "backplane_memory_replay"
  @topic "memory:v2:replay"
  def subscribe, do: Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)

  def enqueue(repo, summary) do
    repo.query!("SELECT pg_notify($1, $2)", [@channel, Jason.encode!(summary)])
    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    {:ok, ref} = Postgrex.Notifications.listen(Backplane.Memory.EventNotifications, @channel)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:notification, _pid, ref, @channel, payload}, %{ref: ref} = state) do
    with {:ok, summary} <- Jason.decode(payload),
         do: Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, {:memory_replay_updated, summary})

    {:noreply, state}
  end
end
