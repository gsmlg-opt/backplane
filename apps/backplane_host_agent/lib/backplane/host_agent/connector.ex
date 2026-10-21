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
          channel: pid(),
          memory: map()
        }

  @doc """
  Connect to the hub described by `config` and join the host_agent channel.
  """
  @spec connect(map()) :: {:ok, result()} | {:error, term()}
  def connect(config) do
    with {:ok, host_id} <- host_id(config),
         {:ok, socket} <- Channel.start_socket(config) do
      case connect_socket(socket, host_id) do
        {:ok, channel, memory} ->
          {:ok,
           %{
             host_id: host_id,
             host_name: Map.get(config, :machine_name),
             socket: socket,
             channel: channel,
             memory: memory
           }}

        {:error, _} = error ->
          Channel.retire_socket(socket)
          error
      end
    end
  end

  defp connect_socket(socket, host_id) do
    with :ok <- wait_for_socket(socket), do: join_channel(socket, host_id)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp join_channel(socket, host_id) do
    case Channel.join(socket, host_id) do
      {:ok, reply, channel} when is_map(reply) -> {:ok, channel, reply}
      {:ok, channel} when is_pid(channel) -> {:ok, channel, %{}}
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
    client =
      Application.get_env(:backplane_host_agent, :socket_client_module, Phoenix.SocketClient)

    wait_for_socket(client, socket, System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_for_socket(client, socket, deadline) do
    snapshot = client.connection_info(socket)

    case snapshot do
      %{attempt_ref: ref, status: status, last_error: error}
      when status == :connected or (status == :disconnected and not is_nil(error)) ->
        # A settled result is authoritative only while it is still the latest attempt.
        case client.connection_info(socket) do
          %{attempt_ref: ^ref, status: ^status, last_error: ^error} ->
            connection_result(status, error)

          _newer ->
            poll_socket(client, socket, deadline)
        end

      {:error, :no_socket_found} ->
        {:error, :not_connected}

      _pending ->
        poll_socket(client, socket, deadline)
    end
  end

  defp poll_socket(client, socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.sleep(min(100, remaining))
      wait_for_socket(client, socket, deadline)
    else
      {:error, :socket_timeout}
    end
  end

  defp connection_result(:connected, nil), do: :ok

  defp connection_result(_status, {:unexpected_status, status}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp connection_result(_status, :cancelled), do: {:error, :not_connected}
  defp connection_result(_status, reason), do: {:error, reason}
end
