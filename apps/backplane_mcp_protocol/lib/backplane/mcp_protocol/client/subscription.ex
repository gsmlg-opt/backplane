defmodule Backplane.McpProtocol.Client.Subscription do
  @moduledoc """
  Cancellable client handle and owner process for one modern subscription.

  The client process owns a process-local ID registry while this process owns
  the acknowledgement gate and transport stream. This keeps long-lived stream
  state out of the ordinary request table and lets HTTP and stdio use their
  distinct cancellation mechanisms.
  """

  use GenServer
  use Backplane.McpProtocol.Logging

  alias Backplane.McpProtocol.MCP.Error

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @registry_key {__MODULE__, :registry}
  @call_buffer 250
  @known_filter_fields ~w(toolsListChanged promptsListChanged resourcesListChanged resourceSubscriptions)

  @enforce_keys [:id, :pid, :client, :subscriber, :requested_notifications]
  defstruct [
    :id,
    :pid,
    :client,
    :subscriber,
    :requested_notifications,
    :notifications,
    :transport,
    :stream,
    acknowledged?: false
  ]

  @type id :: String.t() | integer()

  @type t :: %__MODULE__{
          id: id(),
          pid: pid(),
          client: pid(),
          subscriber: pid(),
          requested_notifications: map(),
          notifications: map() | nil,
          transport: map() | nil,
          stream: term(),
          acknowledged?: boolean()
        }

  defmodule State do
    @moduledoc false

    defstruct [
      :id,
      :client,
      :subscriber,
      :waiter,
      :requested_notifications,
      :notifications,
      :transport,
      :stream,
      :ack_timer,
      :client_monitor,
      :subscriber_monitor,
      :transport_pid,
      :transport_monitor,
      :stream_monitor,
      :close_reason,
      pending_stream_messages: [],
      pending_stream_terminals: [],
      acknowledged?: false,
      close_transport?: true
    ]
  end

  @doc "Normalizes the public list shorthand or the frozen wire filter map."
  @spec normalize_filters(list() | map()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn
      "notifications/tools/list_changed", {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, "toolsListChanged", true)}}

      "notifications/prompts/list_changed", {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, "promptsListChanged", true)}}

      "notifications/resources/list_changed", {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, "resourcesListChanged", true)}}

      _unknown, _acc ->
        {:halt, invalid_filters()}
    end)
  end

  def normalize_filters(filters) when is_map(filters) do
    if valid_filter?(filters), do: {:ok, filters}, else: invalid_filters()
  end

  def normalize_filters(_filters), do: invalid_filters()

  @doc false
  @spec start(map()) :: GenServer.on_start()
  def start(opts) when is_map(opts), do: GenServer.start(__MODULE__, opts)

  @doc false
  @spec attach_stream(pid(), term(), timeout()) :: :ok | {:error, Error.t()}
  def attach_stream(pid, stream, timeout) do
    GenServer.call(pid, {:attach_stream, stream}, timeout)
  catch
    :exit, {:noproc, _call} ->
      {:error, Error.transport(:subscription_attach_failed, %{reason: :noproc})}

    :exit, {:timeout, _call} ->
      {:error, Error.transport(:subscription_attach_timeout)}

    :exit, reason ->
      {:error, Error.transport(:subscription_attach_failed, %{reason: reason})}
  end

  @doc false
  @spec fail(pid(), Error.t()) :: :ok
  def fail(pid, %Error{} = error) do
    GenServer.call(pid, {:fail, error})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec close(pid(), String.t(), timeout()) :: :ok | {:error, Error.t()}
  def close(pid, reason, timeout)
      when is_pid(pid) and is_binary(reason) and is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, {:close, reason, timeout}, timeout + @call_buffer)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:timeout, _call} -> {:error, Error.transport(:subscription_close_timeout)}
    :exit, reason -> {:error, Error.transport(:subscription_close_failed, %{reason: reason})}
  end

  def close(pid, reason, _timeout) when is_pid(pid) and is_binary(reason) do
    {:error, Error.protocol(:invalid_params, %{field: "timeout"})}
  end

  @doc false
  @spec register(id(), pid()) :: :ok
  def register(id, pid) when is_pid(pid) do
    Process.put(@registry_key, Map.put(registry(), id, pid))
    :ok
  end

  @doc false
  @spec unregister(id(), pid()) :: :ok
  def unregister(id, pid) when is_pid(pid) do
    case registry() do
      %{^id => ^pid} = subscriptions -> Process.put(@registry_key, Map.delete(subscriptions, id))
      _subscriptions -> :ok
    end

    :ok
  end

  @doc false
  @spec registered?(id(), pid()) :: boolean()
  def registered?(id, pid) when is_pid(pid), do: Map.get(registry(), id) == pid

  @doc false
  @spec dispatch(map()) :: boolean()
  def dispatch(message) when is_map(message) do
    with {:ok, id} <- message_subscription_id(message),
         pid when is_pid(pid) <- Map.get(registry(), id),
         true <- Process.alive?(pid) do
      GenServer.cast(pid, {:message, message})
      true
    else
      _not_a_subscription_message -> false
    end
  end

  @doc false
  @spec routable?(map()) :: boolean()
  def routable?(%{"params" => %{"_meta" => %{@subscription_id_key => id}}})
      when is_binary(id) or is_integer(id),
      do: true

  def routable?(%{"method" => "notifications/cancelled"}), do: true

  def routable?(_message), do: false

  @doc false
  @spec close_all(String.t(), timeout()) :: :ok
  def close_all(reason, timeout) do
    registry()
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(&close(&1, reason, timeout))

    Process.delete(@registry_key)
    :ok
  end

  @doc false
  @spec client_closing_all(term()) :: :ok
  def client_closing_all(reason) do
    registry()
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(&client_closing(&1, reason))

    :ok
  end

  defp client_closing(pid, reason) do
    GenServer.call(pid, {:client_closing, reason}, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    client = Map.fetch!(opts, :client)
    subscriber = Map.fetch!(opts, :subscriber)
    transport = Map.fetch!(opts, :transport)
    transport_pid = Map.get(opts, :transport_pid) || resolve_transport_pid(transport)
    timeout = Map.fetch!(opts, :timeout)

    state = %State{
      id: Map.fetch!(opts, :id),
      client: client,
      subscriber: subscriber,
      waiter: Map.fetch!(opts, :waiter),
      requested_notifications: Map.fetch!(opts, :requested_notifications),
      transport: transport,
      ack_timer: Process.send_after(self(), :ack_timeout, timeout),
      client_monitor: Process.monitor(client),
      subscriber_monitor: Process.monitor(subscriber),
      transport_pid: transport_pid,
      transport_monitor: monitor_process(transport_pid)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:attach_stream, stream}, _from, state) do
    state = %{
      state
      | stream: stream,
        stream_monitor: monitor_process(stream)
    }

    case drain_pending_stream_messages(state) do
      {:continue, state} ->
        case apply_pending_stream_terminal(state) do
          {:continue, state} -> {:reply, :ok, maybe_acknowledge_waiter(state)}
          {:stop, state} -> {:stop, :normal, :ok, state}
        end

      {:stop, state} ->
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call({:fail, %Error{} = error}, _from, state) do
    {:stop, :normal, :ok, fail_waiter(state, error)}
  end

  def handle_call({:close, reason, timeout}, _from, state) do
    error =
      Error.transport(:request_cancelled, %{
        message: "Subscription cancelled before acknowledgement",
        reason: reason
      })

    result = close_transport_stream(state, reason, timeout)

    {:stop, :normal, result,
     %{fail_waiter(state, error) | close_reason: reason, close_transport?: false}}
  end

  def handle_call({:client_closing, reason}, _from, state) do
    {:stop, state} = client_closed(reason, state)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_cast({:message, message}, state) do
    message |> process_message(state) |> cast_result()
  end

  defp process_message(message, state) do
    cond do
      error_response?(message, state.id) ->
        error = normalize_wire_error(message["error"])
        state = fail_waiter(state, error)

        if state.acknowledged? do
          send(
            state.subscriber,
            {:mcp_subscription_closed, public_handle(state), {:error, error}}
          )
        end

        {:stop, %{state | close_transport?: false}}

      acknowledged_notification?(message, state.id) ->
        notifications = message["params"]["notifications"]

        if valid_acknowledgement?(notifications, state.requested_notifications) do
          if state.ack_timer, do: Process.cancel_timer(state.ack_timer)

          state = %{
            state
            | acknowledged?: true,
              notifications: notifications,
              ack_timer: nil
          }

          {:continue, maybe_acknowledge_waiter(state)}
        else
          {:continue, state}
        end

      cancellation_notification?(message, state.id) ->
        reason = get_in(message, ["params", "reason"]) || "cancelled by server"

        error =
          Error.transport(:request_cancelled, %{
            message: "Subscription cancelled by server",
            reason: reason
          })

        state = fail_waiter(state, error)

        if state.acknowledged? do
          send(
            state.subscriber,
            {:mcp_subscription_closed, public_handle(state), {:error, error}}
          )
        end

        {:stop, %{state | close_transport?: false}}

      graceful_completion?(message, state.id) and state.acknowledged? ->
        if state.ack_timer, do: Process.cancel_timer(state.ack_timer)
        send(state.subscriber, {:mcp_subscription_closed, public_handle(state), :complete})
        {:stop, %{state | close_transport?: false}}

      graceful_completion?(message, state.id) ->
        error =
          Error.transport(:subscription_closed_before_ack, %{
            message: "Subscription completed before acknowledgement"
          })

        {:stop, %{fail_waiter(state, error) | close_transport?: false}}

      subscription_notification?(message, state.id) and state.acknowledged? ->
        send(state.subscriber, {:mcp_subscription, public_handle(state), message})
        {:continue, state}

      true ->
        {:continue, state}
    end
  end

  @impl GenServer
  def handle_info(:ack_timeout, state) do
    error =
      Error.transport(:subscription_ack_timeout, %{
        message: "Subscription acknowledgement timed out"
      })

    {:stop, :normal, fail_waiter(state, error)}
  end

  def handle_info({:mcp_stream_message, stream, id, message}, %{stream: nil, id: id} = state) do
    pending = [{stream, message} | state.pending_stream_messages]
    {:noreply, %{state | pending_stream_messages: pending}}
  end

  def handle_info({:mcp_stream_message, stream, id, message}, %{stream: stream, id: id} = state) do
    message |> process_message(state) |> info_result()
  end

  def handle_info({:mcp_stream_message, _stream, _id, _message}, state), do: {:noreply, state}

  def handle_info({:mcp_stream_error, stream, reason}, %{stream: nil} = state) do
    {:noreply, buffer_stream_terminal(state, {:error, stream, reason})}
  end

  def handle_info({:mcp_stream_error, stream, reason}, %{stream: stream} = state) do
    reason |> stream_failed(state) |> info_result()
  end

  def handle_info({:mcp_stream_closed, stream, reason}, %{stream: nil} = state) do
    {:noreply, buffer_stream_terminal(state, {:closed, stream, reason})}
  end

  def handle_info({:mcp_stream_closed, stream, reason}, %{stream: stream} = state) do
    reason |> stream_closed(state) |> info_result()
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{stream_monitor: ref, stream: pid} = state
      ) do
    error =
      Error.transport(:subscription_stream_down, %{
        message: "Subscription stream stopped",
        reason: reason
      })

    if state.acknowledged? do
      send(state.subscriber, {:mcp_subscription_closed, public_handle(state), {:error, error}})
    end

    {:stop, :normal, %{fail_waiter(state, error) | close_transport?: false}}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{transport_monitor: ref, transport_pid: pid} = state
      ) do
    error =
      Error.transport(:subscription_transport_down, %{
        message: "Subscription transport stopped",
        reason: reason
      })

    state = fail_waiter(state, error)

    if state.acknowledged? do
      send(state.subscriber, {:mcp_subscription_closed, public_handle(state), {:error, error}})
    end

    {:stop, :normal, %{state | close_transport?: false}}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{client_monitor: ref, client: pid} = state
      ) do
    reason |> client_closed(state) |> info_result()
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{subscriber_monitor: ref, subscriber: pid} = state
      ) do
    error =
      Error.transport(:subscription_owner_down, %{
        message: "Subscription owner stopped",
        reason: reason
      })

    {:stop, :normal, fail_waiter(state, error)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.ack_timer, do: Process.cancel_timer(state.ack_timer)
    if state.client_monitor, do: Process.demonitor(state.client_monitor, [:flush])
    if state.subscriber_monitor, do: Process.demonitor(state.subscriber_monitor, [:flush])
    if state.transport_monitor, do: Process.demonitor(state.transport_monitor, [:flush])
    if state.stream_monitor, do: Process.demonitor(state.stream_monitor, [:flush])

    if state.close_transport? and not is_nil(state.stream) do
      close_transport_stream(state, state.close_reason || "subscription closed", 1_000)
    end

    send(state.client, {:mcp_subscription_down, state.id, self()})
    :ok
  end

  defp cast_result({:continue, state}), do: {:noreply, state}
  defp cast_result({:stop, state}), do: {:stop, :normal, state}

  defp info_result({:continue, state}), do: {:noreply, state}
  defp info_result({:stop, state}), do: {:stop, :normal, state}

  defp drain_pending_stream_messages(state) do
    state.pending_stream_messages
    |> Enum.reverse()
    |> Enum.reduce_while({:continue, %{state | pending_stream_messages: []}}, fn
      {stream, message}, {:continue, %{stream: stream} = state} ->
        case process_message(message, state) do
          {:continue, state} -> {:cont, {:continue, state}}
          {:stop, state} -> {:halt, {:stop, state}}
        end

      {_foreign_stream, _message}, result ->
        {:cont, result}
    end)
  end

  defp apply_pending_stream_terminal(state) do
    stream = state.stream

    terminal =
      state.pending_stream_terminals
      |> Enum.reverse()
      |> Enum.find(fn {_kind, terminal_stream, _reason} -> terminal_stream == stream end)

    state = %{state | pending_stream_terminals: []}

    case terminal do
      {:error, ^stream, reason} -> stream_failed(reason, state)
      {:closed, ^stream, reason} -> stream_closed(reason, state)
      nil -> {:continue, state}
    end
  end

  defp buffer_stream_terminal(state, terminal) do
    %{state | pending_stream_terminals: [terminal | state.pending_stream_terminals]}
  end

  defp stream_failed(reason, state) do
    error = stream_error(reason)
    state = fail_waiter(state, error)

    if state.acknowledged? do
      send(state.subscriber, {:mcp_subscription_closed, public_handle(state), {:error, error}})
    end

    {:stop, %{state | close_transport?: false}}
  end

  defp stream_closed(reason, state) do
    error = Error.transport(:subscription_stream_closed, %{reason: reason})
    state = fail_waiter(state, error)

    if state.acknowledged? do
      send(state.subscriber, {:mcp_subscription_closed, public_handle(state), {:error, error}})
    end

    {:stop, %{state | close_transport?: false}}
  end

  defp client_closed(reason, state) do
    error =
      Error.transport(:client_terminated, %{
        message: "Subscription client stopped",
        reason: reason
      })

    state = fail_waiter(state, error)

    if state.acknowledged? do
      send(state.subscriber, {:mcp_subscription_closed, public_handle(state), {:error, error}})
    end

    {:stop, state}
  end

  defp maybe_acknowledge_waiter(
         %State{acknowledged?: true, stream: stream, waiter: waiter} = state
       )
       when not is_nil(stream) and not is_nil(waiter) do
    GenServer.reply(waiter, {:ok, public_handle(state)})
    %{state | waiter: nil}
  end

  defp maybe_acknowledge_waiter(state), do: state

  defp fail_waiter(%State{waiter: nil} = state, _error), do: state

  defp fail_waiter(state, %Error{} = error) do
    GenServer.reply(state.waiter, {:error, error})
    %{state | waiter: nil}
  end

  defp close_transport_stream(%{stream: nil}, _reason, _timeout), do: :ok

  defp close_transport_stream(%{transport_pid: nil}, _reason, _timeout) do
    {:error, Error.transport(:subscription_transport_down)}
  end

  defp close_transport_stream(state, reason, timeout) do
    layer = state.transport.layer

    if function_exported?(layer, :close_stream, 3) do
      case layer.close_stream(state.transport_pid, state.stream,
             subscription_id: state.id,
             reason: reason,
             timeout: timeout
           ) do
        :ok ->
          :ok

        {:error, reason} when reason in [:stream_close_timeout, :timeout] ->
          {:error, Error.transport(:subscription_close_timeout)}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, Error.transport(:subscription_close_failed, %{reason: reason})}
      end
    else
      {:error, Error.transport(:unsupported_operation, %{operation: :close_stream})}
    end
  rescue
    exception ->
      {:error,
       Error.transport(:subscription_close_failed, %{
         reason: {:exception, Exception.message(exception)}
       })}
  catch
    :exit, {:timeout, _call} ->
      {:error, Error.transport(:subscription_close_timeout)}

    kind, reason ->
      {:error, Error.transport(:subscription_close_failed, %{reason: {kind, reason}})}
  end

  defp public_handle(state) do
    %__MODULE__{
      id: state.id,
      pid: self(),
      client: state.client,
      subscriber: state.subscriber,
      requested_notifications: state.requested_notifications,
      notifications: state.notifications,
      transport: state.transport,
      stream: state.stream,
      acknowledged?: state.acknowledged?
    }
  end

  defp message_subscription_id(%{
         "method" => "notifications/cancelled",
         "params" => %{"requestId" => id}
       })
       when is_binary(id) or is_integer(id),
       do: {:ok, id}

  defp message_subscription_id(%{"params" => %{"_meta" => %{@subscription_id_key => id}}})
       when is_binary(id) or is_integer(id),
       do: {:ok, id}

  defp message_subscription_id(%{
         "id" => id,
         "result" => %{"_meta" => %{@subscription_id_key => id}}
       })
       when is_binary(id) or is_integer(id),
       do: {:ok, id}

  defp message_subscription_id(%{"id" => id, "error" => %{} = _error})
       when is_binary(id) or is_integer(id),
       do: {:ok, id}

  defp message_subscription_id(_message), do: :error

  defp acknowledged_notification?(
         %{
           "jsonrpc" => "2.0",
           "method" => "notifications/subscriptions/acknowledged",
           "params" => %{
             "notifications" => notifications,
             "_meta" => %{@subscription_id_key => id}
           }
         } = message,
         id
       )
       when is_map(notifications) do
    not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
      not Map.has_key?(message, "error")
  end

  defp acknowledged_notification?(_message, _id), do: false

  defp cancellation_notification?(
         %{
           "jsonrpc" => "2.0",
           "method" => "notifications/cancelled",
           "params" => %{"requestId" => id}
         } = message,
         id
       ) do
    not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
      not Map.has_key?(message, "error")
  end

  defp cancellation_notification?(_message, _id), do: false

  defp subscription_notification?(
         %{
           "jsonrpc" => "2.0",
           "method" => method,
           "params" => %{"_meta" => %{@subscription_id_key => id}}
         } = message,
         id
       )
       when is_binary(method) do
    method != "notifications/subscriptions/acknowledged" and
      not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
      not Map.has_key?(message, "error")
  end

  defp subscription_notification?(_message, _id), do: false

  defp graceful_completion?(
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "result" => %{"resultType" => "complete", "_meta" => %{@subscription_id_key => id}}
         } = message,
         id
       ) do
    not Map.has_key?(message, "method") and not Map.has_key?(message, "error")
  end

  defp graceful_completion?(_message, _id), do: false

  defp error_response?(%{"jsonrpc" => "2.0", "id" => id, "error" => %{} = error} = message, id) do
    is_integer(error["code"]) and is_binary(error["message"]) and
      not Map.has_key?(message, "method") and not Map.has_key?(message, "result")
  end

  defp error_response?(_message, _id), do: false

  defp normalize_wire_error(%{"code" => code, "message" => message} = error)
       when is_integer(code) and is_binary(message) do
    Error.from_json_rpc(error)
  end

  defp normalize_wire_error(_error), do: Error.transport(:malformed_response)

  defp valid_acknowledgement?(acknowledged, requested) do
    valid_filter?(acknowledged) and
      Enum.all?(acknowledged, fn
        {field, true}
        when field in ~w(toolsListChanged promptsListChanged resourcesListChanged) ->
          requested[field] == true

        {field, false}
        when field in ~w(toolsListChanged promptsListChanged resourcesListChanged) ->
          Map.has_key?(requested, field)

        {"resourceSubscriptions", uris} ->
          requested_uris = Map.get(requested, "resourceSubscriptions", [])
          Enum.all?(uris, &(&1 in requested_uris))

        _unknown ->
          false
      end)
  end

  defp valid_filter?(filter) when is_map(filter) do
    Enum.all?(filter, fn
      {field, value} when field in ~w(toolsListChanged promptsListChanged resourcesListChanged) ->
        is_boolean(value)

      {"resourceSubscriptions", uris} ->
        is_list(uris) and Enum.all?(uris, &is_binary/1)

      {field, _value} ->
        field in @known_filter_fields and false
    end)
  end

  defp valid_filter?(_filter), do: false

  defp stream_error({_stream, reason}), do: stream_error(reason)

  defp stream_error(reason) do
    Error.transport(:subscription_stream_failed, %{reason: reason})
  end

  defp invalid_filters do
    {:error, Error.protocol(:invalid_params, %{field: "notifications"})}
  end

  defp resolve_transport_pid(%{name: name}) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> pid
      _missing -> nil
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp monitor_process(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_process(_pid), do: nil

  defp registry do
    Process.get(@registry_key, %{})
  end
end
