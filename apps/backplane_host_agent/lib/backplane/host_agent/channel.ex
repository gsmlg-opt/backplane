defmodule Backplane.HostAgent.Channel do
  @moduledoc """
  Thin wrapper around phoenix_socket_client for host-agent channel operations.
  """

  @doc "Starts the Phoenix socket connection for a host-agent config."
  def start_socket(config) do
    headers = [{"X-Backplane-Host-Token", Map.fetch!(config, :token)}]

    socket_client_module =
      Application.get_env(:backplane_host_agent, :socket_client_module, Phoenix.SocketClient)

    with {:ok, socket} <-
           socket_client_module.start_link(
             url: Map.fetch!(config, :socket_url),
             headers: headers,
             reconnect?: true,
             reconnect_interval: min(Map.get(config, :interval_ms, 60_000), 60_000),
             # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#96
             auto_connect: false,
             # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#95
             transport_opts: [headers: headers]
           ),
         :ok <- socket_client_module.connect(socket) do
      {:ok, socket}
    end
  end

  @doc "Joins the host-agent channel for the authenticated host."
  def join(socket, host_id) do
    Phoenix.SocketClient.Channel.join(socket, "host_agent:#{host_id}", %{})
  end

  @doc "Pushes an event through the joined host-agent channel."
  def push(channel, event, payload, timeout \\ 5_000) do
    Phoenix.SocketClient.Channel.push(channel, event, payload, timeout)
  end
end
