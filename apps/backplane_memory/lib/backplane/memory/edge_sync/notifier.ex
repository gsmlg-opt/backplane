defmodule Backplane.Memory.EdgeSync.Notifier do
  @moduledoc "Optional content-free PostgreSQL wakeups; polling is always authoritative."
  use GenServer
  @channel "bpm_memory_edge_available"
  @topic "memory:edge:available"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)

  @impl true
  def init(_opts) do
    options =
      Backplane.Memory.EventNotifier.connection_options()
      |> Keyword.delete(:name)
      |> Keyword.merge(auto_reconnect: true, sync_connect: false)

    {:ok, connection} = Postgrex.Notifications.start_link(options)

    case Postgrex.Notifications.listen(connection, @channel) do
      {status, ref} when status in [:ok, :eventually] ->
        {:ok, %{connection: connection, listen_ref: ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {:notification, pid, ref, @channel, payload},
        %{connection: pid, listen_ref: ref} = state
      ) do
    with true <- is_binary(payload) and byte_size(payload) < 8000,
         {:ok, hint} <- Jason.decode(payload),
         true <- valid?(hint) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, {:memory_available, hint})
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp valid?(hint) when is_map(hint) do
    Enum.sort(Map.keys(hint)) == ~w(current_revision memory_space_id namespace scope) and
      Ecto.UUID.cast(hint["memory_space_id"]) != :error and
      is_binary(hint["scope"]) and String.trim(hint["scope"]) != "" and
      is_binary(hint["namespace"]) and String.trim(hint["namespace"]) != "" and
      is_integer(hint["current_revision"]) and hint["current_revision"] >= 0
  end

  defp valid?(_), do: false
end
