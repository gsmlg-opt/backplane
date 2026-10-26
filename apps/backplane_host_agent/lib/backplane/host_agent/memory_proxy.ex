defmodule Backplane.HostAgent.MemoryProxy do
  @moduledoc """
  Forwards memory requests from the local HTTP API to the Backplane hub
  through the established host-agent WebSocket channel.

  The active channel pid is cached after the channel is joined; the router reads
  it at request time. When the full connection is available, the proxy also
  keeps the agent config so local requests can reconnect after a WebSocket
  channel process dies.
  """

  alias Backplane.HostAgent.{Channel, Connector, Telemetry, Trace}
  alias Backplane.HostAgent.Memory.Access

  @methods ~w(remember recall list get forget stats lifecycle_context)
  @method_set MapSet.new(@methods)
  @reconnect_lock_resource {__MODULE__, :reconnect}

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
    :persistent_term.put(__MODULE__, Map.put(state_map(), :channel, pid))
    :ok
  end

  @doc """
  Keep the agent config for future reconnect attempts before a channel exists.
  """
  @spec set_config(map() | struct()) :: :ok
  def set_config(config) when not is_nil(config) do
    :persistent_term.put(__MODULE__, Map.put(state_map(), :config, config))
    :ok
  end

  @doc "Keep a rejected connection fail-closed until a fresh authenticated join succeeds."
  def set_connection_error(reason, owner) do
    case state() do
      %{connection_owner: ^owner} = current -> remember_rejection(current, reason)
      _ -> :ok
    end
  end

  @doc false
  def retain_credential_rejection(reason, channel, generation)

  def retain_credential_rejection(
        %{"code" => "unauthorized", "retryable" => false} = reason,
        channel,
        generation
      )
      when is_pid(channel) do
    case state() do
      %{channel: ^channel, memory_generation: %{id: ^generation}} = current ->
        :persistent_term.put(__MODULE__, Map.put(current, :connection_error, reason))

      _ ->
        :ok
    end

    :ok
  end

  def retain_credential_rejection(_, _, _), do: :ok

  defp remember_rejection(current, reason) do
    if connection_rejection?(reason) do
      :persistent_term.put(__MODULE__, Map.put(current, :connection_error, reason))

      if current[:memory_generation],
        do: Access.fence(:all, :connection_rejected, current.memory_generation)
    end

    :ok
  end

  @doc "Check a retained credential rejection before accepting a protected local command."
  def authorize_command do
    case state() do
      %{connection_error: reason} -> {:error, reason}
      _ -> :ok
    end
  end

  @doc "Check credentials and the negotiated scope before using default private memory."
  def authorize_private do
    with :ok <- authorize_command() do
      case state() do
        %{private_binding_error: reason} when not is_nil(reason) -> {:error, reason}
        _ -> :ok
      end
    end
  end

  defp connection_rejection?(reason) when reason in [:unauthorized, "unauthorized"], do: true
  defp connection_rejection?(%{"retryable" => false}), do: true
  defp connection_rejection?(%{retryable: false}), do: true
  defp connection_rejection?(%{"reason" => "unauthorized"}), do: true
  defp connection_rejection?(%{reason: "unauthorized"}), do: true
  defp connection_rejection?({:unexpected_status, status}) when status in 400..499, do: true
  defp connection_rejection?(_), do: false

  @doc "Assign reconnect ownership to the worker before exposing the local API."
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

  @doc "Release only the calling worker's connection without enabling request reconnects."
  def clear_connection_owner(owner) do
    case state() do
      %{connection_owner: ^owner} = current ->
        :persistent_term.put(__MODULE__, %{current | connection_owner: nil, channel: nil})

      _ ->
        :ok
    end

    :ok
  end

  defp stop_owned_channel(channel) when is_pid(channel) do
    if channel != self() and Process.alive?(channel), do: Channel.retire(channel)
    :ok
  end

  defp stop_owned_channel(_channel), do: :ok

  @doc """
  Set the live connection used for local memory calls.

  `connection` is the map returned by `Backplane.HostAgent.Connector.connect/1`.
  The config is kept so the proxy can reconnect if the cached channel process is
  terminated by socket disconnect/reconnect handling.
  """
  @spec set_connection(map(), map() | struct()) :: :ok
  def set_connection(%{channel: channel} = connection, config) when is_pid(channel) do
    previous = state_map()
    socket = Map.get(connection, :socket)

    unlink_process(channel)
    unlink_process(socket)
    close_replaced_socket(Map.get(previous, :socket), socket)

    next = %{
      channel: channel,
      config: config,
      host_id: Map.get(connection, :host_id),
      host_name: Map.get(connection, :host_name),
      socket: socket,
      private_binding_error: private_binding_error(connection, config, previous)
    }

    next =
      if Map.has_key?(previous, :connection_owner),
        do: Map.put(next, :connection_owner, previous.connection_owner),
        else: next

    next = Map.put(next, :memory_generation, connection[:memory_generation])

    inventory_result =
      case connection do
        %{memory: %{"extensions" => extensions} = memory, memory_generation: generation}
        when is_list(extensions) ->
          if "memory_access.v1" in extensions,
            do: Access.install_inventory(generation, memory),
            else: :ok

        _ ->
          :ok
      end

    :persistent_term.put(__MODULE__, next)
    inventory_result
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
  into the arguments before being forwarded to the hub unless
  `inject_agent_id: false` is passed.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(method, args, opts \\ []) when is_binary(method) and is_map(args) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    Telemetry.span_memory_call(method, agent_id, args, fn ->
      do_call(method, args, opts, agent_id)
    end)
  end

  defp do_call(method, args, opts, agent_id) do
    cond do
      not valid_method?(method) ->
        {:error, {:unknown_method, method}}

      true ->
        arguments =
          if method != "get" and Keyword.get(opts, :inject_agent_id, true),
            do: Map.put(args, "agent_id", agent_id),
            else: args

        payload =
          %{
            "method" => method,
            "arguments" => arguments
          }
          |> trace_payload()

        push_module =
          Keyword.get(opts, :channel_module) ||
            Application.get_env(:backplane_host_agent, :channel_module, Channel)

        connector_module =
          Keyword.get(opts, :connector_module) ||
            Application.get_env(:backplane_host_agent, :connector_module, Connector)

        timeout = request_timeout(method, Keyword.get(opts, :timeout, 5_000))

        case Keyword.get(opts, :access) do
          %{"access_id" => id, "authority_version" => version} = access
          when is_binary(id) and is_integer(version) ->
            case state() do
              %{channel: channel, memory_generation: %{id: generation}} when is_pid(channel) ->
                if generation == Keyword.get(opts, :connection_generation),
                  do:
                    push_channel(
                      push_module,
                      channel,
                      Map.put(payload, "access", access),
                      timeout,
                      generation
                    ),
                  else: {:error, :stale_connection}

              _ ->
                {:error, :not_connected}
            end

          nil ->
            push_with_reconnect(push_module, connector_module, payload, timeout)

          _ ->
            {:error, :invalid_request}
        end
    end
  end

  defp push_with_reconnect(push_module, connector_module, payload, timeout) do
    with :ok <- authorize_private(),
         {:ok, channel} <- ensure_channel(connector_module, push_module),
         :ok <- authorize_private() do
      case push_private_channel(push_module, channel, payload, timeout) do
        {:error, :not_connected} ->
          mark_channel_dead()

          with {:ok, reconnected_channel} <- reconnect(connector_module, push_module, channel),
               :ok <- authorize_private() do
            push_private_channel(push_module, reconnected_channel, payload, timeout)
          end

        result ->
          result
      end
    end
  end

  defp ensure_channel(connector_module, channel_module) do
    case state() do
      %{connection_error: reason} ->
        {:error, reason}

      %{connection_owner: owner} when not is_pid(owner) ->
        {:error, :not_connected}

      %{connection_owner: owner} ->
        if Process.alive?(owner),
          do: ensure_owned_or_unmanaged_channel(connector_module, channel_module),
          else: {:error, :not_connected}

      _ ->
        ensure_owned_or_unmanaged_channel(connector_module, channel_module)
    end
  end

  defp ensure_owned_or_unmanaged_channel(connector_module, channel_module) do
    case state() do
      %{channel: channel} when is_pid(channel) ->
        if Process.alive?(channel) do
          {:ok, channel}
        else
          mark_channel_dead()
          reconnect(connector_module, channel_module, channel)
        end

      channel when is_pid(channel) ->
        if Process.alive?(channel) do
          {:ok, channel}
        else
          set_channel(nil)
          {:error, :not_connected}
        end

      %{config: _config} ->
        reconnect(connector_module, channel_module)

      _ ->
        {:error, :not_connected}
    end
  end

  defp push_private_channel(push_module, channel, %{"method" => "get"} = payload, timeout) do
    identity = connection_identity(state())

    if elem(identity, 0) == channel,
      do: push_channel(push_module, channel, payload, timeout, {:connection, identity}),
      else: {:error, :stale_connection}
  end

  defp push_private_channel(push_module, channel, payload, timeout),
    do: push_channel(push_module, channel, payload, timeout)

  defp push_channel(push_module, channel, payload, timeout, generation \\ nil) do
    connection = state()

    if (payload["method"] == "get" or Map.has_key?(payload, "access")) and
         not selected_connection?(connection, channel, generation) do
      {:error, :stale_connection}
    else
      push_selected_channel(push_module, channel, payload, timeout, generation, connection)
    end
  end

  defp selected_connection?(connection, channel, {:connection, expected}) do
    elem(expected, 0) == channel and connection_identity(connection) == expected
  end

  defp selected_connection?(connection, channel, generation) do
    case connection_identity(connection) do
      {^channel, %{id: ^generation}} -> true
      {^channel, _snapshot_generation} when is_nil(generation) -> true
      _ -> false
    end
  end

  defp push_selected_channel(push_module, channel, payload, timeout, generation, connection) do
    result =
      case safe_push(push_module, channel, payload, timeout) do
        {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
        {:ok, %{"error" => error}} -> {:error, error}
        {:ok, reply} -> {:ok, reply}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_reply, other}}
      end

    case {result, state()} do
      {{:error, reason}, %{channel: ^channel} = current} ->
        if Map.has_key?(payload, "access"),
          do: retain_credential_rejection(reason, channel, generation),
          else: remember_rejection(current, reason)

      _ ->
        :ok
    end

    if payload["method"] == "get" and
         connection_identity(connection) != connection_identity(state()),
       do: {:error, :stale_connection},
       else: result
  end

  defp connection_identity(%{channel: channel} = state),
    do: {channel, state[:memory_generation]}

  defp connection_identity(channel), do: {channel, nil}

  defp safe_push(push_module, channel, payload, timeout) do
    try do
      push_module.push(channel, "memory_call", payload, timeout)
    catch
      :exit, reason -> {:error, push_exit_reason(reason)}
    end
  end

  defp request_timeout("lifecycle_context", timeout)
       when is_integer(timeout) and timeout > 0,
       do: min(timeout, 1_500)

  defp request_timeout("lifecycle_context", _timeout), do: 1_500
  defp request_timeout(_method, timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp request_timeout(_method, _timeout), do: 5_000

  defp reconnect(connector_module, channel_module, observed_channel \\ nil) do
    case state() do
      %{connection_owner: owner} = current ->
        # Even if the owner has stopped, requests must not become a second
        # connection manager. Its replacement claims ownership during boot.
        if is_pid(owner) and Process.alive?(owner),
          do:
            send(owner, {:memory_connection_lost, observed_channel || Map.get(current, :channel)})

        {:error, :not_connected}

      _ ->
        reconnect_unmanaged(connector_module, channel_module)
    end
  end

  defp reconnect_unmanaged(connector_module, channel_module) do
    :global.trans(
      {@reconnect_lock_resource, self()},
      fn -> reconnect_locked(connector_module, channel_module) end,
      [node()]
    )
  catch
    :exit, reason -> {:error, {:reconnect_lock_failed, reason}}
  end

  defp reconnect_locked(connector_module, channel_module) do
    case live_channel() do
      {:ok, channel} ->
        {:ok, channel}

      {:error, _reason} ->
        case rejoin_existing_socket(channel_module) do
          {:ok, channel} -> {:ok, channel}
          {:error, _reason} -> connect_new_socket(connector_module)
        end
    end
  end

  defp live_channel do
    case state() do
      %{channel: channel} when is_pid(channel) ->
        if Process.alive?(channel), do: {:ok, channel}, else: {:error, :not_connected}

      channel when is_pid(channel) ->
        if Process.alive?(channel), do: {:ok, channel}, else: {:error, :not_connected}

      _ ->
        {:error, :not_connected}
    end
  end

  defp rejoin_existing_socket(channel_module) do
    case state() do
      %{socket: socket, host_id: host_id} when is_pid(socket) and is_binary(host_id) ->
        if Process.alive?(socket) and function_exported?(channel_module, :join, 2) do
          case channel_module.join(socket, host_id) do
            {:ok, reply, channel} when is_pid(channel) ->
              store_rejoined_channel(channel, reply)

            {:ok, channel} when is_pid(channel) ->
              store_rejoined_channel(channel)

            {:error, {:already_joined, channel}} when is_pid(channel) ->
              store_rejoined_channel(channel)

            {:error, {:already_started, channel}} when is_pid(channel) ->
              store_rejoined_channel(channel)

            {:error, reason} ->
              {:error, reason}

            other ->
              {:error, {:unexpected_join_reply, other}}
          end
        else
          {:error, :not_connected}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  defp connect_new_socket(connector_module) do
    case state() do
      %{config: config} = observed when not is_nil(config) ->
        case connector_module.connect(config) do
          {:ok, %{channel: channel} = connection} when is_pid(channel) ->
            set_connection(connection, config)
            {:ok, channel}

          {:error, reason} ->
            if state() == observed, do: remember_rejection(observed, reason)
            {:error, {:reconnect_failed, reason}}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  defp store_rejoined_channel(channel) do
    unlink_process(channel)

    case state() do
      %{} = current ->
        :persistent_term.put(__MODULE__, Map.put(current, :channel, channel))
        {:ok, channel}

      _ ->
        set_channel(channel)
        {:ok, channel}
    end
  end

  defp store_rejoined_channel(channel, reply) when is_map(reply) do
    case state() do
      %{config: config} = current ->
        unlink_process(channel)

        next =
          current
          |> Map.put(:channel, channel)
          |> Map.put(
            :private_binding_error,
            private_binding_error(%{memory: reply}, config, current)
          )

        :persistent_term.put(__MODULE__, next)
        {:ok, channel}

      _ ->
        store_rejoined_channel(channel)
    end
  end

  defp store_rejoined_channel(channel, _reply), do: store_rejoined_channel(channel)

  defp private_binding_error(connection, config, previous) do
    memory_config = Map.get(config, :memory) || Map.get(config, "memory") || %{}
    bound_scope = Map.get(memory_config, :bound_scope) || Map.get(memory_config, "bound_scope")
    scopes = private_scopes(Map.get(connection, :memory))

    if is_binary(bound_scope) and bound_scope != "" and scopes != [] do
      if bound_scope in scopes, do: nil, else: :memory_scope_mismatch
    else
      Map.get(previous, :private_binding_error)
    end
  end

  defp private_scopes(%{
         "selected" => "host_memory.v2",
         "default_access_id" => id,
         "accesses" => accesses
       })
       when is_list(accesses) do
    case Enum.find(accesses, &(&1["access_id"] == id)) do
      %{"partition" => %{"namespace" => "private", "scope" => scope}} -> [scope]
      _ -> []
    end
  end

  defp private_scopes(_memory), do: []

  defp mark_channel_dead do
    case state() do
      %{connection_owner: _owner} -> :ok
      %{config: _config} = current -> :persistent_term.put(__MODULE__, %{current | channel: nil})
      _ -> set_channel(nil)
    end
  end

  defp state do
    :persistent_term.get(__MODULE__, nil)
  end

  defp state_map do
    case state() do
      %{} = current -> current
      channel when is_pid(channel) -> %{channel: channel}
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

      # WORKAROUND(upstream): gsmlg-dev/phoenix_socket_client#97
      # disconnect/1 marks the client disconnected but can leave the websocket
      # transport process/socket open. Stop the old socket supervisor when a
      # replacement socket has been installed so the linked transport releases
      # its file descriptor.
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

  defp push_exit_reason({:noproc, _}), do: :not_connected
  defp push_exit_reason(:noproc), do: :not_connected
  defp push_exit_reason({:normal, _}), do: :not_connected
  defp push_exit_reason(:normal), do: :not_connected
  defp push_exit_reason({:timeout, _}), do: :timeout
  defp push_exit_reason(:timeout), do: :timeout
  defp push_exit_reason(reason), do: {:channel_exit, reason}

  defp trace_payload(payload) do
    case Trace.child_ctx(Trace.current()) do
      nil -> payload
      ctx -> Map.put(payload, "traceparent", Trace.to_traceparent(ctx))
    end
  end
end
