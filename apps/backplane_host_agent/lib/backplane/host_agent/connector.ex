defmodule Backplane.HostAgent.Connector do
  @moduledoc """
  Establishes a connection from a host agent to a Backplane hub.

  Wraps the bootstrap: WebSocket connect with host_id → channel join.
  Returns the socket pid, channel pid, and resolved host metadata so a worker
  can be started with a ready-to-use channel.
  """

  alias Backplane.HostAgent.Channel

  @type result :: %{
          host_id: String.t(),
          host_name: String.t(),
          socket: pid(),
          channel: pid()
        }

  @doc """
  Connect to the hub described by `config` and join the host_agent channel.
  """
  @spec connect(map()) :: {:ok, result()} | {:error, term()}
  def connect(config) do
    with {:ok, host_id} <- host_id(config),
         {:ok, socket} <- Channel.start_socket(config),
         :ok <- wait_for_socket(socket),
         {:ok, channel} <- join_channel(socket, host_id) do
      {:ok,
       %{
         host_id: host_id,
         host_name: Map.get(config, :machine_name),
         socket: socket,
         channel: channel
       }}
    end
  end

  defp join_channel(socket, host_id) do
    case Channel.join(socket, host_id) do
      {:ok, _reply, channel} -> {:ok, channel}
      {:ok, channel} when is_pid(channel) -> {:ok, channel}
      {:error, reason} -> {:error, reason}
    end
  end

  defp host_id(config) do
    case Map.get(config, :host_id) do
      host_id when is_binary(host_id) and host_id != "" and host_id != "REPLACE_WITH_AGENT_ID" ->
        {:ok, host_id}

      _ ->
        {:error, {:missing_required_config, [:host_id]}}
    end
  end

  defp wait_for_socket(socket) do
    wait_for_socket(socket, 50)
  end

  defp wait_for_socket(_socket, 0), do: {:error, :socket_timeout}

  defp wait_for_socket(socket, attempts_left) do
    if Phoenix.SocketClient.connected?(socket) do
      :ok
    else
      Process.sleep(100)
      wait_for_socket(socket, attempts_left - 1)
    end
  end
end
