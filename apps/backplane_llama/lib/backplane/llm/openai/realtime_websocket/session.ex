defmodule Backplane.LLM.OpenAI.RealtimeWebSocket.Session do
  @moduledoc """
  Owns one native Realtime upstream connection, from handshake through cleanup.

  A temporary supervised child is opened before the downstream upgrade. The
  request process owns it until the WebSock callback attaches; either owner's
  death closes the upstream. It never reconnects or replays a possible submission.
  Only one upstream message is delivered at a time, and acknowledgement follows
  the downstream server's completed local write. Cleanup is not cancellation of
  a provider response.
  """

  use GenServer, restart: :temporary

  alias Backplane.LLM.OpenAI.RealtimeWebSocket.Policy
  alias Backplane.LLM.AccessEvent
  alias HTTP.{ClientCompletion, WebSocket}
  alias HTTP.WebSocket.Event

  @message_limit 2_097_152
  @opening_timeout 5_000
  @write_timeout 5_000
  @attach_timeout 5_000
  @cleanup_timeout 2_000
  @call_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def open(pid), do: safe_call(pid, :open)
  def attach(pid, owner), do: safe_call(pid, {:attach, owner})

  def send(pid, bytes) do
    deadline = System.monotonic_time(:millisecond) + @call_timeout
    safe_call(pid, {:send, bytes, deadline})
  end

  def ack(pid, ref), do: GenServer.cast(pid, {:ack, self(), ref})
  def close(pid), do: safe_call(pid, :close)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    policy = Keyword.fetch!(opts, :policy)
    service = Map.get(policy, :service, %{})
    lifetime = Map.get(service, :max_session_ms, 3_600_000)
    input_limit = Map.get(service, :max_request_bytes, 50_000_000)
    output_limit = Map.get(service, :max_response_bytes, 100_000_000)
    message_limit = min(@message_limit, input_limit)

    options = [
      headers: Keyword.fetch!(opts, :headers),
      mode: :browser,
      delivery: :ack,
      http_version: :http1,
      tls_backend: :ex_ssl,
      connect_timeout: @opening_timeout,
      opening_timeout: @opening_timeout,
      write_timeout: @write_timeout,
      idle_timeout: min(lifetime, 300_000),
      close_timeout: 1_000,
      max_message_size: min(@message_limit, output_limit),
      max_frame_bytes: min(@message_limit, output_limit),
      max_read_bytes: 2 * @message_limit + 20,
      max_queue_bytes: 2 * @message_limit + 7,
      max_queue_events: 16,
      max_send_queue: @message_limit + 14,
      max_send_frames: 1,
      telemetry_url: nil
    ]

    case WebSocket.new(Keyword.fetch!(opts, :url), Keyword.get(opts, :protocols, []), options) do
      %WebSocket{} = socket ->
        timer = Process.send_after(self(), :opening_expired, @opening_timeout + 100)

        {:ok,
         %{
           socket: socket,
           owner: owner,
           owner_monitor: Process.monitor(owner),
           socket_monitor: Process.monitor(socket.pid),
           policy: policy,
           access: Keyword.get(opts, :access),
           lifetime_timer: Process.send_after(self(), :session_expired, lifetime),
           input_limit: input_limit,
           output_limit: output_limit,
           input_bytes: 0,
           output_bytes: 0,
           opening_timer: timer,
           attach_timer: nil,
           opening: :pending,
           waiter: nil,
           attached: false,
           pending: nil,
           pending_timer: nil,
           terminal: nil,
           write: nil,
           max_outbound: message_limit
         }}

      {:error, _} ->
        {:stop, :invalid_transport_options}
    end
  end

  @impl true
  def handle_call(
        :open,
        {owner, _} = from,
        %{owner: owner, opening: :pending, waiter: nil} = state
      ),
      do: {:noreply, %{state | waiter: from}}

  def handle_call(:open, {owner, _}, %{owner: owner, opening: {:ok, metadata}} = state),
    do: {:reply, {:ok, metadata}, state}

  def handle_call(:open, {owner, _}, %{owner: owner, opening: {:error, _, _} = error} = state),
    do: {:stop, :normal, error, state}

  def handle_call({:attach, owner}, {owner, _}, %{attached: false, opening: {:ok, _}} = state) do
    Process.cancel_timer(state.attach_timer)
    Process.demonitor(state.owner_monitor, [:flush])
    state = %{state | attached: true, owner: owner, owner_monitor: Process.monitor(owner)}
    state = if state.pending, do: deliver(state), else: state
    state = notify_terminal(state)
    {:reply, :ok, state}
  end

  def handle_call(
        {:send, bytes, deadline},
        {owner, _} = from,
        %{owner: owner, attached: true} = state
      )
      when is_binary(bytes) and is_integer(deadline) do
    with true <- submission_time?(deadline),
         true <- is_nil(state.terminal) and is_nil(state.write),
         {:ok, encoded, policy} <- prepare(state.policy, bytes),
         true <- byte_size(encoded) <= state.max_outbound,
         true <- state.input_bytes + byte_size(encoded) <= state.input_limit,
         true <- Process.alive?(owner) and submission_time?(deadline) do
      case WebSocket.send_ack(state.socket, encoded) do
        {:ok, ref} ->
          timer = Process.send_after(self(), {:write_expired, ref}, @write_timeout + 100)

          {:noreply,
           %{
             state
             | write: %{ref: ref, from: from, timer: timer},
               input_bytes: state.input_bytes + byte_size(encoded),
               policy: policy
           }}

        {:error, _} ->
          # Even a local call timeout can race transport admission. Never invite
          # a retry based on an unobservable submission boundary.
          {:stop, :normal, {:error, :submission_unknown}, state}
      end
    else
      false -> {:reply, {:error, :message_not_admitted}, state}
      {:error, code} -> {:reply, {:error, code}, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = fail_write(state)
    result = cleanup(state.socket)
    {:stop, :normal, result, state}
  end

  def handle_call(_message, _from, state),
    do: {:reply, {:error, :invalid_session_operation}, state}

  @impl true
  def handle_cast({:ack, owner, ref}, %{owner: owner, pending: {_bytes, ref}} = state) do
    if state.pending_timer, do: Process.cancel_timer(state.pending_timer)
    WebSocket.acknowledge(state.socket, ref)
    {:noreply, notify_terminal(%{state | pending: nil, pending_timer: nil})}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {WebSocket, socket, %Event.Open{handshake: metadata}},
        %{socket: socket} = state
      ) do
    Process.cancel_timer(state.opening_timer)

    case handshake(metadata, socket) do
      {:ok, metadata, limit} ->
        if state.waiter, do: GenServer.reply(state.waiter, {:ok, metadata})
        timer = Process.send_after(self(), :attach_expired, @attach_timeout)

        {:noreply,
         %{
           state
           | opening: {:ok, metadata},
             waiter: nil,
             attach_timer: timer,
             max_outbound: min(limit, state.max_outbound)
         }}

      {:error, code} ->
        opening_failed(state, code, metadata)
    end
  end

  def handle_info(
        {WebSocket, socket, %Event.Message{data: bytes}, ref},
        %{socket: socket, pending: nil, terminal: nil} = state
      )
      when is_binary(bytes) and byte_size(bytes) <= @message_limit do
    if state.output_bytes + byte_size(bytes) <= state.output_limit do
      state = %{
        state
        | pending: {bytes, ref},
          output_bytes: state.output_bytes + byte_size(bytes)
      }

      state = if state.attached, do: deliver(state), else: state
      {:noreply, state}
    else
      WebSocket.acknowledge(state.socket, ref)
      terminal(state, 1009)
    end
  end

  def handle_info(
        {WebSocket, socket, %Event.Message{}, ref},
        %{socket: socket, terminal: code} = state
      )
      when is_integer(code) do
    WebSocket.acknowledge(state.socket, ref)
    {:noreply, state}
  end

  def handle_info({WebSocket, socket, %Event.Message{}, _ref}, %{socket: socket} = state),
    do: terminal(state, 1003)

  def handle_info(
        {WebSocket, socket, %Event.Error{handshake: metadata}},
        %{socket: socket, opening: :pending} = state
      ),
      do: opening_failed(state, :upstream_handshake_failed, metadata)

  def handle_info({WebSocket, socket, %Event.Error{}}, %{socket: socket} = state),
    do: terminal(state, 1011)

  def handle_info({WebSocket, socket, %Event.Close{code: code}}, %{socket: socket} = state),
    do: terminal(state, close_code(code))

  def handle_info(
        {WebSocket, socket, {:send_result, ref, :ok}},
        %{socket: socket, write: %{ref: ref} = write} = state
      ) do
    Process.cancel_timer(write.timer)
    GenServer.reply(write.from, :ok)
    {:noreply, %{state | write: nil}}
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, {:error, _}}},
        %{socket: socket, write: %{ref: ref}} = state
      ),
      do: terminal(state, 1011)

  def handle_info({:write_expired, ref}, %{write: %{ref: ref}} = state), do: terminal(state, 1011)

  def handle_info({:delivery_expired, ref}, %{pending: {_bytes, ref}} = state),
    do: {:stop, :normal, fail_write(state)}

  def handle_info(:session_expired, state), do: {:stop, :normal, fail_write(state)}

  def handle_info(:opening_expired, %{opening: :pending} = state),
    do: opening_failed(state, :upstream_timeout, nil)

  def handle_info(:attach_expired, %{attached: false} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, fail_write(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{socket_monitor: ref} = state),
    do: terminal(state, 1011)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state.socket)
    finalize_access(state)
  end

  defp finalize_access(%{access: %AccessEvent{} = access} = state) do
    status =
      case state.opening do
        {:ok, _} -> 101
        {:error, _, %{status: status}} -> status
        _ -> 502
      end

    outcome =
      cond do
        status != 101 -> :error
        state.terminal in [1000, 1001] -> :success
        is_nil(state.terminal) -> :cancelled
        true -> :error
      end

    # Realtime usage events remain native downstream bytes. Connection records
    # deliberately leave token totals unavailable rather than infer billing.
    AccessEvent.finalize(
      %{access | request_bytes: state.input_bytes},
      %Plug.Conn{status: status},
      outcome,
      error_kind: :transport,
      error_code: "realtime_connection_closed"
    )
  end

  defp finalize_access(_state), do: :ok

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp safe_call(pid, message) do
    GenServer.call(pid, message, @call_timeout)
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  # Leave time for transport admission and the local write acknowledgement. A
  # queued/slow policy check must never submit after its caller abandoned the call.
  defp submission_time?(deadline) do
    System.monotonic_time(:millisecond) + 2 * @write_timeout + 250 < deadline
  end

  defp prepare(policy, bytes) do
    if byte_size(bytes) <= @message_limit,
      do: Policy.prepare(policy, bytes),
      else: {:error, :message_too_big}
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  defp handshake(%{status: 101, truncated?: false} = metadata, socket) do
    {:ok, Map.put(metadata, :protocol, WebSocket.protocol(socket)), @message_limit}
  end

  defp handshake(_, _), do: {:error, :invalid_handshake_metadata}

  defp opening_failed(state, code, metadata) do
    Process.cancel_timer(state.opening_timer)
    cleanup(state.socket)
    result = {:error, code, metadata}

    if state.waiter do
      GenServer.reply(state.waiter, result)
      {:stop, :normal, %{state | waiter: nil, opening: result}}
    else
      timer = Process.send_after(self(), :attach_expired, @attach_timeout)
      {:noreply, %{state | opening: result, attach_timer: timer}}
    end
  end

  defp terminal(%{opening: :pending} = state, _code),
    do: opening_failed(state, :upstream_closed, nil)

  defp terminal(state, code) do
    state =
      state |> fail_write() |> Map.put(:terminal, state.terminal || code) |> notify_terminal()

    {:noreply, state}
  end

  defp fail_write(%{write: nil} = state), do: state

  defp fail_write(%{write: write} = state) do
    Process.cancel_timer(write.timer)
    GenServer.reply(write.from, {:error, :submission_unknown})
    %{state | write: nil}
  end

  defp deliver(%{pending: {bytes, ref}} = state) do
    Kernel.send(state.owner, {:realtime_event, self(), bytes, ref})
    %{state | pending_timer: Process.send_after(self(), {:delivery_expired, ref}, @call_timeout)}
  end

  defp notify_terminal(%{attached: true, pending: nil, terminal: code} = state)
       when is_integer(code) do
    Kernel.send(state.owner, {:realtime_closed, self(), code})
    state
  end

  defp notify_terminal(state), do: state
  defp close_code(code) when code in [1000, 1001, 1008, 1009, 1011, 1012, 1013], do: code
  defp close_code(_), do: 1011

  defp cleanup(socket) do
    WebSocket.close(socket)
    ClientCompletion.await(WebSocket.completion(socket), @cleanup_timeout)
  end
end
