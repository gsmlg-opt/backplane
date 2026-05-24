defmodule Backplane.HostAgent.Connector do
  @moduledoc """
  Establishes a connection from a host agent to a Backplane hub.

  Wraps the three-step bootstrap: HTTP whoami → WebSocket connect → channel join.
  Returns the socket pid, channel pid, and resolved host metadata so a worker
  can be started with a ready-to-use channel.
  """

  alias Backplane.HostAgent.Channel

  @whoami_path "/api/host-agent/whoami"

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
    with {:ok, host} <- fetch_whoami(config),
         {:ok, socket} <- Channel.start_socket(config),
         :ok <- wait_for_socket(socket),
         {:ok, channel} <- join_channel(socket, host["id"]) do
      {:ok,
       %{
         host_id: host["id"],
         host_name: host["name"],
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

  defp fetch_whoami(config) do
    hub_url = Map.fetch!(config, :hub_url)
    token = Map.fetch!(config, :token)
    url = hub_url <> @whoami_path

    headers = [{"x-backplane-host-token", token}, {"accept", "application/json"}]

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:whoami_decode, reason}}
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:whoami_status, status}}

      {:error, reason} ->
        {:error, {:whoami_transport, reason}}
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
