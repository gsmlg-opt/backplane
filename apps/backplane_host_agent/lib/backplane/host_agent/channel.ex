defmodule Backplane.HostAgent.Channel do
  @moduledoc """
  Thin wrapper around phoenix_socket_client for host-agent channel operations.
  """

  alias Backplane.HostAgent.Memory.{Edge.Protection, Mirror, Syncer}

  @doc "Starts the Phoenix socket connection for a host-agent config."
  def start_socket(config) do
    headers = [{"X-Backplane-Host-Token", Map.fetch!(config, :token)}]

    socket_client_module =
      Application.get_env(:backplane_host_agent, :socket_client_module, Phoenix.SocketClient)

    channel_module =
      Application.get_env(
        :backplane_host_agent,
        :socket_channel_module,
        Backplane.HostAgent.AgentChannel
      )

    opts = [
      url: Map.fetch!(config, :socket_url),
      headers: headers,
      reconnect?: true,
      reconnect_interval: min(Map.get(config, :interval_ms, 60_000), 60_000),
      default_channel_module: channel_module,
      # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#96
      auto_connect: false,
      # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#95
      transport_opts: [headers: headers]
    ]

    with {:ok, socket} <- start_or_reuse_socket(socket_client_module, opts),
         :ok <- ensure_connected(socket_client_module, socket) do
      {:ok, socket}
    end
  end

  defp start_or_reuse_socket(socket_client_module, opts) do
    case socket_client_module.start_link(opts) do
      {:ok, socket} -> {:ok, socket}
      {:error, {:already_started, socket}} when is_pid(socket) -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_connected(socket_client_module, socket) do
    if function_exported?(socket_client_module, :connected?, 1) and
         socket_client_module.connected?(socket) do
      :ok
    else
      socket_client_module.connect(socket)
    end
  end

  @doc "Joins the host-agent channel for the authenticated host."
  def join(socket, host_id) do
    channel_join_module =
      Application.get_env(
        :backplane_host_agent,
        :socket_channel_join_module,
        Phoenix.SocketClient.Channel
      )

    channel_join_module.join(socket, "host_agent:#{host_id}", join_payload())
  end

  defp join_payload do
    payload = Syncer.join_payload()

    case edge_offer() do
      {:ok, offer} -> Map.put(payload, "memory_v2", offer)
      :disabled -> payload
    end
  end

  defp edge_offer do
    config = Application.get_env(:backplane_host_agent, :memory_host_sync_v2, %{})
    mirror_module = Application.get_env(:backplane_host_agent, :edge_mirror_module, Mirror)

    if Protection.status(config) == :plaintext_development do
      case mirror_module.offer(config: config) do
        {:ok, %{"offers" => ["host_memory.v2"], "partitions" => _} = offer} -> {:ok, offer}
        _ -> :disabled
      end
    else
      :disabled
    end
  end

  @doc "Pushes an event through the joined host-agent channel."
  def push(channel, event, payload, timeout \\ 5_000) do
    Phoenix.SocketClient.Channel.push(channel, event, payload, timeout)
  end
end
