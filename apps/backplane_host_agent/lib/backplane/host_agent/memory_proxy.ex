defmodule Backplane.HostAgent.MemoryProxy do
  @moduledoc """
  Forwards memory requests from the local HTTP API to the Backplane hub
  through the established host-agent WebSocket channel.

  The active channel pid is cached after the channel is joined; the router reads
  it at request time. When the full connection is available, the proxy also
  keeps the agent config so local requests can reconnect after a WebSocket
  channel process dies.
  """

  alias Backplane.HostAgent.{Channel, Connector}

  @methods ~w(remember recall list forget stats)
  @method_set MapSet.new(@methods)

  @doc "List of memory methods exposed by the HTTP API."
  def methods, do: @methods

  @doc "True if `method` is one of the supported memory methods."
  def valid_method?(method) when is_binary(method), do: MapSet.member?(@method_set, method)
  def valid_method?(_), do: false

  @doc """
  Set the live channel pid that proxy requests should be pushed through.
  """
  @spec set_channel(pid() | nil) :: :ok
  def set_channel(nil) do
    _ = :persistent_term.erase(__MODULE__)
    :ok
  end

  def set_channel(pid) when is_pid(pid) do
    :persistent_term.put(__MODULE__, %{channel: pid})
    :ok
  end

  @doc """
  Set the live connection used for local memory calls.

  `connection` is the map returned by `Backplane.HostAgent.Connector.connect/1`.
  The config is kept so the proxy can reconnect if the cached channel process is
  terminated by socket disconnect/reconnect handling.
  """
  @spec set_connection(map(), map() | struct()) :: :ok
  def set_connection(%{channel: channel} = connection, config) when is_pid(channel) do
    :persistent_term.put(__MODULE__, %{
      channel: channel,
      config: config,
      host_id: Map.get(connection, :host_id),
      host_name: Map.get(connection, :host_name),
      socket: Map.get(connection, :socket)
    })

    :ok
  end

  @doc "Get the current channel pid, or nil."
  @spec channel() :: pid() | nil
  def channel do
    case state() do
      %{channel: channel} when is_pid(channel) -> channel
      channel when is_pid(channel) -> channel
      _ -> nil
    end
  end

  @doc """
  Invoke a memory method with `args`. `agent_id` is required and is injected
  into the arguments before being forwarded to the hub.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(method, args, opts \\ []) when is_binary(method) and is_map(args) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    cond do
      not valid_method?(method) ->
        {:error, {:unknown_method, method}}

      is_nil(channel()) ->
        {:error, :not_connected}

      true ->
        payload = %{
          "method" => method,
          "arguments" => Map.put(args, "agent_id", agent_id)
        }

        push_module =
          Keyword.get(opts, :channel_module) ||
            Application.get_env(:backplane_host_agent, :channel_module, Channel)

        connector_module =
          Keyword.get(opts, :connector_module) ||
            Application.get_env(:backplane_host_agent, :connector_module, Connector)

        push_with_reconnect(push_module, connector_module, payload)
    end
  end

  defp push_with_reconnect(push_module, connector_module, payload) do
    with {:ok, channel} <- ensure_channel(connector_module) do
      case push_channel(push_module, channel, payload) do
        {:error, :not_connected} ->
          mark_channel_dead()

          with {:ok, reconnected_channel} <- reconnect(connector_module) do
            push_channel(push_module, reconnected_channel, payload)
          end

        result ->
          result
      end
    end
  end

  defp ensure_channel(connector_module) do
    case state() do
      %{channel: channel} when is_pid(channel) ->
        if Process.alive?(channel) do
          {:ok, channel}
        else
          mark_channel_dead()
          reconnect(connector_module)
        end

      channel when is_pid(channel) ->
        if Process.alive?(channel) do
          {:ok, channel}
        else
          set_channel(nil)
          {:error, :not_connected}
        end

      %{config: _config} ->
        reconnect(connector_module)

      _ ->
        {:error, :not_connected}
    end
  end

  defp push_channel(push_module, channel, payload) do
    case safe_push(push_module, channel, payload) do
      {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp safe_push(push_module, channel, payload) do
    try do
      push_module.push(channel, "memory_call", payload)
    catch
      :exit, reason -> {:error, push_exit_reason(reason)}
    end
  end

  defp reconnect(connector_module) do
    case state() do
      %{config: config} when not is_nil(config) ->
        case connector_module.connect(config) do
          {:ok, %{channel: channel} = connection} when is_pid(channel) ->
            set_connection(connection, config)
            {:ok, channel}

          {:error, reason} ->
            {:error, {:reconnect_failed, reason}}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  defp mark_channel_dead do
    case state() do
      %{config: _config} = current -> :persistent_term.put(__MODULE__, %{current | channel: nil})
      _ -> set_channel(nil)
    end
  end

  defp state do
    :persistent_term.get(__MODULE__, nil)
  end

  defp push_exit_reason({:noproc, _}), do: :not_connected
  defp push_exit_reason(:noproc), do: :not_connected
  defp push_exit_reason({:normal, _}), do: :not_connected
  defp push_exit_reason(:normal), do: :not_connected
  defp push_exit_reason({:timeout, _}), do: :timeout
  defp push_exit_reason(:timeout), do: :timeout
  defp push_exit_reason(reason), do: {:channel_exit, reason}
end
