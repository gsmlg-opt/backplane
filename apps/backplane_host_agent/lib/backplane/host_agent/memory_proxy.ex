defmodule Backplane.HostAgent.MemoryProxy do
  @moduledoc """
  Tracks the live host-agent channel used to reach the Backplane gateway.

  The worker publishes the joined channel here; `Backplane.HostAgent.HubProxy`
  and the capture uploader read it at request time. Reconnection is owned by
  the worker, never by request paths.
  """

  alias Backplane.HostAgent.Channel

  @doc "Set the live channel pid that gateway requests should be pushed through."
  @spec set_channel(pid() | nil) :: :ok
  def set_channel(nil) do
    _ = :persistent_term.erase(__MODULE__)
    :ok
  end

  def set_channel(pid) when is_pid(pid) do
    :persistent_term.put(__MODULE__, Map.put(state_map(), :channel, pid))
    :ok
  end

  @doc "Assign connection ownership to the worker before exposing the local API."
  @spec set_connection_owner(pid()) :: :ok | {:error, :connection_owned}
  def set_connection_owner(owner) when is_pid(owner) do
    current = state_map()
    previous = Map.get(current, :connection_owner)

    cond do
      previous == owner ->
        :ok

      is_pid(previous) and Process.alive?(previous) ->
        {:error, :connection_owned}

      true ->
        if Map.has_key?(current, :connection_owner),
          do: stop_owned_channel(Map.get(current, :channel))

        :persistent_term.put(
          __MODULE__,
          current |> Map.put(:connection_owner, owner) |> Map.put(:channel, nil)
        )

        :ok
    end
  end

  @doc "Release only the calling worker's connection."
  @spec clear_connection_owner(pid()) :: :ok
  def clear_connection_owner(owner) do
    case state() do
      %{connection_owner: ^owner} = current ->
        :persistent_term.put(__MODULE__, %{current | connection_owner: nil, channel: nil})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Publish the live connection returned by `Backplane.HostAgent.Connector.connect/1`.

  A replaced socket is disconnected so only one gateway connection is active.
  """
  @spec set_connection(map()) :: :ok
  def set_connection(%{channel: channel} = connection) when is_pid(channel) do
    previous = state_map()
    socket = Map.get(connection, :socket)

    unlink_process(channel)
    unlink_process(socket)
    close_replaced_socket(Map.get(previous, :socket), socket)

    next =
      previous
      |> Map.take([:connection_owner])
      |> Map.merge(%{channel: channel, socket: socket})

    :persistent_term.put(__MODULE__, next)
    :ok
  end

  @doc "Get the current channel pid, or nil."
  @spec channel() :: pid() | nil
  def channel do
    case state() do
      %{channel: channel} when is_pid(channel) -> channel
      _ -> nil
    end
  end

  defp stop_owned_channel(channel) when is_pid(channel) do
    if channel != self() and Process.alive?(channel), do: Channel.retire(channel)
    :ok
  end

  defp stop_owned_channel(_channel), do: :ok

  defp state, do: :persistent_term.get(__MODULE__, nil)

  defp state_map do
    case state() do
      %{} = current -> current
      _ -> %{}
    end
  end

  defp close_replaced_socket(socket, socket), do: :ok

  defp close_replaced_socket(socket, _new_socket) when is_pid(socket) do
    if Process.alive?(socket) do
      socket_client_module =
        Application.get_env(:backplane_host_agent, :socket_client_module, Phoenix.SocketClient)

      if function_exported?(socket_client_module, :disconnect, 1) do
        socket_client_module.disconnect(socket)
      end

      # Retire the replaced client's supervision tree as well as its connection.
      stop_socket_supervisor(socket)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_replaced_socket(_socket, _new_socket), do: :ok

  defp stop_socket_supervisor(socket) when is_pid(socket) do
    if Process.alive?(socket) do
      Supervisor.stop(socket, :normal, 1_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp unlink_process(pid) when is_pid(pid) do
    Process.unlink(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp unlink_process(_), do: :ok
end
