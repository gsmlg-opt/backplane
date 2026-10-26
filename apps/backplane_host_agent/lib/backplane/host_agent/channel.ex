defmodule Backplane.HostAgent.Channel do
  @moduledoc """
  Thin wrapper around phoenix_socket_client for host-agent channel operations.
  """

  alias Backplane.HostAgent.Memory.{Edge.Protection, Mirror}

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
      # Worker owns reconnect and refreshes all consumers after a fresh join.
      reconnect?: false,
      reconnect_interval: min(Map.get(config, :interval_ms, 60_000), 60_000),
      default_channel_module: channel_module,
      # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#96
      auto_connect: false,
      # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#95
      transport_opts: [headers: headers]
    ]

    with {:ok, socket} <- start_or_reuse_socket(socket_client_module, opts) do
      case ensure_connected(socket_client_module, socket) do
        :ok ->
          {:ok, socket}

        {:error, _} = error ->
          retire_socket(socket)
          error
      end
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
    case edge_offer() do
      {:ok, offer} ->
        Map.put(
          %{},
          "memory_v2",
          Map.put(offer, "extensions", [
            "memory_access.v1",
            "memory_commands.v2",
            "memory_sources.v1",
            "hermes_capture.v1",
            "openclaw_source.v1",
            "openclaw_capture.v1"
          ])
        )

      :disabled ->
        Map.put(%{}, "memory_v2", %{
          "offers" => ["host_memory.v2"],
          "partitions" => [],
          "max_frame_bytes" => 524_288,
          "extensions" => [
            "memory_access.v1",
            "memory_commands.v2",
            "memory_sources.v1",
            "hermes_capture.v1",
            "openclaw_source.v1",
            "openclaw_capture.v1"
          ]
        })
    end
  end

  defp edge_offer do
    config = Application.get_env(:backplane_host_agent, :memory_host_sync, %{})
    mirror_module = Application.get_env(:backplane_host_agent, :edge_mirror_module, Mirror)

    if Protection.plaintext_development?(config) do
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

  @doc false
  def retire_socket(socket) when is_pid(socket) do
    Process.unlink(socket)

    client =
      Application.get_env(:backplane_host_agent, :socket_client_module, Phoenix.SocketClient)

    try do
      try do
        client.disconnect(socket)

        # disconnect/1 is asynchronous. Let cancellation finish while the parent
        # supervisor can still serve the socket's cleanup calls.
        if function_exported?(client, :connection_info, 1), do: client.connection_info(socket)
      catch
        :exit, _ -> :ok
      end

      retire(socket)
    catch
      :exit, _ -> {:error, :socket_retirement_failed}
    end
  end

  @doc false
  def retire(channel) when is_pid(channel) do
    ref = Process.monitor(channel)

    try do
      GenServer.stop(channel, :normal, 5_000)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:timeout, _} -> Process.exit(channel, :kill)
    end

    receive do
      {:DOWN, ^ref, :process, ^channel, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        exit(:channel_retirement_timeout)
    end
  end
end
