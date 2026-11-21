defmodule Backplane.LLM.ResponsesWebSocket.Session do
  @moduledoc """
  Owns one native Responses upstream connection, from handshake through cleanup.

  A temporary supervised child reserves capacity before the downstream upgrade.
  The request process owns it until the WebSock callback attaches. The upstream
  opens when the first create selects a route. Owner death closes the upstream.
  The session never reconnects or replays a possible submission.
  Only one upstream message is delivered at a time, and acknowledgement follows
  the downstream server's completed local write. Cleanup is not cancellation of
  a provider response.

  Uses `HTTP.WebSocket` in `mode: :proxy` over HTTP/1 with `automatic_pong: true`
  so the gateway can send hop-local upstream Ping frames and track Pong liveness
  without interfering with downstream traffic or injecting synthetic JSON events.
  """

  use GenServer, restart: :temporary

  alias Backplane.LLM.{AccessEvent, ResponsesWebSocket}
  alias Backplane.LLM.ResponsesWebSocket.{Limits, Policy, ResponseAccess}
  alias HTTP.{ClientCompletion, WebSocket}
  alias HTTP.WebSocket.Event

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(upstream): gsmlg-dev/http_fetch#174
  # `http_web_socket` 1.0.0-rc.20's `HTTP.WebSocket.Handshake.@metadata_headers`
  # only retains `retry-after` and `x-codex-websocket-max-unfragmented-message-bytes`,
  # filtering out `x-codex-websocket-max-message-bytes`. Real-socket upstream
  # peer-cap propagation requires adopting the release that resolves #174.
  @peer_limit_header "x-codex-websocket-max-message-bytes"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def open(pid), do: safe_call(pid, :open, call_timeout())
  def attach(pid, owner), do: safe_call(pid, {:attach, owner}, call_timeout())

  def connect(pid, bytes) do
    timeout = call_timeout()
    deadline = now_ms() + timeout
    safe_call(pid, {:connect, bytes, deadline}, timeout)
  end

  def send(pid, bytes) do
    timeout = call_timeout()
    deadline = now_ms() + timeout
    safe_call(pid, {:send, bytes, deadline}, timeout)
  end

  @doc false
  def submit(pid, submit_ref, bytes, deadline) when is_reference(submit_ref) do
    GenServer.cast(pid, {:submit, self(), submit_ref, bytes, deadline})
  end

  @doc false
  def note_activity(pid, direction) when direction in [:inbound, :outbound] do
    GenServer.cast(pid, {:activity, self(), direction})
  end

  def ack(pid, ref), do: GenServer.cast(pid, {:ack, self(), ref})

  def close(pid, close_info \\ nil) do
    safe_call(pid, {:close, close_info}, cleanup_call_timeout())
  end

  @doc false
  def parse_handshake(
        %{status: 101, truncated?: false, headers: headers} = metadata,
        protocol,
        max_message_bytes
      ) do
    case HTTP.Headers.get_all(headers, @peer_limit_header) do
      [] ->
        {:ok, Map.put(metadata, :protocol, protocol), max_message_bytes}

      [value] ->
        case Integer.parse(value) do
          {limit, ""} when limit > 0 ->
            {:ok, Map.put(metadata, :protocol, protocol), min(limit, max_message_bytes)}

          _ ->
            {:error, :invalid_peer_message_limit}
        end

      [_ | _] ->
        {:error, :invalid_peer_message_limit}
    end
  end

  def parse_handshake(_, _, _), do: {:error, :invalid_handshake_metadata}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    limits = Keyword.get_lazy(opts, :limits, &Limits.current/0)
    access = Keyword.get(opts, :access)
    now = now_ms()

    state = %{
      socket: nil,
      owner: owner,
      owner_monitor: Process.monitor(owner),
      socket_monitor: nil,
      limits: limits,
      codec_options: Limits.codec_options(limits),
      request: Keyword.get(opts, :request),
      access: access,
      close_access: access,
      remote_ip: Keyword.get(opts, :remote_ip),
      policy: nil,
      response_access: nil,
      opening_timer: nil,
      attach_timer: nil,
      first_create_timer: nil,
      upstream_ping_timer: nil,
      upstream_ping: nil,
      opening: :awaiting_route,
      waiter: nil,
      attached: false,
      pending: nil,
      pending_timer: nil,
      terminal: nil,
      write: nil,
      prep_worker: nil,
      active_submit: nil,
      submit_queue: :queue.new(),
      max_outbound: limits.max_message_bytes,
      started_at_mono: now,
      last_inbound_at_mono: nil,
      last_outbound_at_mono: nil,
      last_upstream_inbound_at_mono: nil,
      close_info: nil,
      close_logged?: false,
      hooks: Keyword.get(opts, :hooks, %{})
    }

    if Keyword.has_key?(opts, :url) do
      open_transport(opts, state, limits.opening_timeout_ms)
    else
      {:ok,
       %{
         state
         | attach_timer: Process.send_after(self(), :attach_expired, limits.attach_timeout_ms)
       }}
    end
  end

  defp open_transport(opts, state, opening_timeout) do
    url = Keyword.fetch!(opts, :url)
    limits = state.limits
    max_message_bytes = limits.max_message_bytes
    effective_msg = max(max_message_bytes, 125)
    opening_timeout = max(opening_timeout, 1)
    connect_timeout = min(limits.connect_timeout_ms, opening_timeout)

    max_queue_bytes =
      if effective_msg <= 1_048_576,
        do: 2 * effective_msg + 7,
        else: effective_msg + 1_048_576 + 7

    options = [
      headers: Keyword.fetch!(opts, :headers),
      mode: :proxy,
      automatic_pong: true,
      delivery: :ack,
      http_version: :http1,
      connect_timeout: connect_timeout,
      opening_timeout: opening_timeout,
      write_timeout: limits.write_timeout_ms,
      idle_timeout: limits.upstream_idle_timeout_ms,
      close_timeout: limits.close_timeout_ms,
      max_message_size: max_message_bytes,
      max_frame_bytes: max_message_bytes,
      max_read_bytes: effective_msg + 1_114_121,
      max_queue_bytes: max_queue_bytes,
      max_queue_events: 16,
      max_send_queue: effective_msg + 256,
      max_send_frames: 2,
      telemetry_url: nil
    ]

    options = options ++ Relayixir.Proxy.EnvironmentProxy.websocket_options(url, opening_timeout)

    case WebSocket.new(url, Keyword.get(opts, :protocols, []), options) do
      %WebSocket{} = socket ->
        timer = Process.send_after(self(), :opening_expired, opening_timeout + 100)
        access = Keyword.get(opts, :access) || state.access
        remote_ip = Keyword.get(opts, :remote_ip) || state.remote_ip

        {:ok,
         %{
           state
           | socket: socket,
             socket_monitor: Process.monitor(socket.pid),
             access: access,
             close_access: access || state.close_access,
             remote_ip: remote_ip,
             policy: Keyword.fetch!(opts, :policy),
             response_access: ResponseAccess.new(access, remote_ip, limits),
             opening_timer: timer,
             opening: :pending
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

  def handle_call({:attach, owner}, {owner, _}, %{attached: false, opening: opening} = state)
      when opening == :awaiting_route or elem(opening, 0) == :ok do
    cancel_timer(state.attach_timer)
    Process.demonitor(state.owner_monitor, [:flush])

    first_create_timer =
      if opening == :awaiting_route,
        do: Process.send_after(self(), :first_create_expired, state.limits.first_create_timeout_ms)

    state = %{
      state
      | attached: true,
        owner: owner,
        owner_monitor: Process.monitor(owner),
        attach_timer: nil,
        first_create_timer: first_create_timer
    }

    state = if state.pending, do: deliver(state), else: state
    state = notify_terminal(state)
    {:reply, :ok, state}
  end

  def handle_call(
        {:connect, bytes, deadline},
        {owner, _} = from,
        %{owner: owner, attached: true, opening: :awaiting_route} = state
      ) do
    cancel_timer(state.first_create_timer)
    next_state = %{state | first_create_timer: nil, request: nil, last_inbound_at_mono: now_ms()}

    with {:ok, opts, _params} <-
           ResponsesWebSocket.route_with_params(
             state.request,
             state.access,
             bytes,
             state.codec_options
           ),
         remaining when remaining > 0 <- remaining_ms(deadline),
         true <- Process.alive?(owner),
         {:ok, state} <-
           open_transport(opts, next_state, min(state.limits.opening_timeout_ms, remaining)) do
      {:noreply, %{state | waiter: from}}
    else
      {:error, {status, code}} = error ->
        next_state =
          record_close(next_state, %{
            initiator: :gateway,
            cause: code,
            status: status,
            local_close_code: if(status >= 500, do: 1011, else: 1008)
          })

        {:stop, :normal, error, next_state}

      _ ->
        next_state =
          record_close(next_state, %{
            initiator: :gateway,
            cause: "submission_expired",
            status: 408,
            local_close_code: 1011
          })

        {:stop, :normal, {:error, :session_unavailable}, next_state}
    end
  end

  def handle_call(
        {:send, bytes, deadline},
        {owner, _} = from,
        %{owner: owner, attached: true, opening: {:ok, _}} = state
      )
      when is_binary(bytes) and is_integer(deadline) do
    state = %{state | last_inbound_at_mono: now_ms()}

    with true <- remaining_ms(deadline) > 0,
         true <- is_nil(state.terminal) and is_nil(state.write),
         {:ok, encoded} <- prepare(state, bytes),
         :ok <- check_outbound_size(encoded, state.max_outbound),
         remaining when remaining > 0 <- remaining_ms(deadline),
         true <- Process.alive?(owner) do
      admit_upstream_write(state, encoded, remaining, {:call, from})
    else
      false -> {:reply, {:error, :message_not_admitted}, state}
      0 -> {:reply, {:error, :message_not_admitted}, state}
      {:error, code} -> {:reply, {:error, code}, state}
    end
  end

  def handle_call({:close, close_info}, _from, state) do
    state =
      state
      |> maybe_record_close(close_info)
      |> cancel_prep_worker()
      |> fail_write()
      |> cancel_upstream_ping()

    result = cleanup(state.socket, state.limits.cleanup_timeout_ms)
    state = finalize_session_close(state)
    {:stop, :normal, result, state}
  end

  def handle_call(_message, _from, state),
    do: {:reply, {:error, :invalid_session_operation}, state}

  @impl true
  def handle_cast({:ack, owner, ref}, %{owner: owner, pending: {_bytes, ref}} = state) do
    cancel_timer(state.pending_timer)
    WebSocket.acknowledge(state.socket, ref)

    {:noreply,
     state
     |> Map.put(:pending, nil)
     |> Map.put(:pending_timer, nil)
     |> Map.put(:last_outbound_at_mono, now_ms())
     |> notify_terminal()}
  end

  def handle_cast({:activity, owner, :inbound}, %{owner: owner} = state),
    do: {:noreply, %{state | last_inbound_at_mono: now_ms()}}

  def handle_cast({:activity, owner, :outbound}, %{owner: owner} = state),
    do: {:noreply, %{state | last_outbound_at_mono: now_ms()}}

  def handle_cast(
        {:submit, owner, submit_ref, bytes, deadline},
        %{owner: owner, attached: true} = state
      )
      when is_reference(submit_ref) and is_binary(bytes) and is_integer(deadline) do
    state = %{state | last_inbound_at_mono: now_ms()}

    cond do
      not is_nil(state.terminal) ->
        notify_submit(state, submit_ref, {:reject_fatal, state.terminal, "Session closed", nil})
        {:noreply, state}

      is_nil(state.active_submit) ->
        {:noreply, start_submit(state, %{ref: submit_ref, bytes: bytes, deadline: deadline})}

      :queue.len(state.submit_queue) < state.limits.max_pending_submits ->
        item = %{ref: submit_ref, bytes: bytes, deadline: deadline}
        {:noreply, %{state | submit_queue: :queue.in(item, state.submit_queue)}}

      true ->
        notify_submit(state, submit_ref, {:reject_request, 429, "submission_queue_full", nil})
        {:noreply, state}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {WebSocket, socket, %Event.Open{handshake: metadata}},
        %{socket: socket} = state
      ) do
    cancel_timer(state.opening_timer)

    case parse_handshake(metadata, WebSocket.protocol(socket), state.limits.max_message_bytes) do
      {:ok, metadata, limit} ->
        log_open(state, {:ok, metadata})
        if state.waiter, do: GenServer.reply(state.waiter, {:ok, metadata})

        attach_timer =
          unless state.attached,
            do: Process.send_after(self(), :attach_expired, state.limits.attach_timeout_ms)

        state =
          %{
            state
            | opening: {:ok, metadata},
              opening_timer: nil,
              waiter: nil,
              attach_timer: attach_timer,
              max_outbound: limit,
              access: nil,
              last_upstream_inbound_at_mono: now_ms()
          }
          |> schedule_upstream_ping()

        case state.active_submit do
          %{phase: :opening, params: params} = submit ->
            {:noreply, start_prepare_worker(state, submit, {:decoded, params})}

          _ ->
            {:noreply, state}
        end

      {:error, code} ->
        opening_failed(state, code, metadata)
    end
  end

  def handle_info(
        {WebSocket, socket, %Event.Frame{opcode: :ping}, ref},
        %{socket: socket} = state
      ) do
    WebSocket.acknowledge(socket, ref)
    {:noreply, %{state | last_upstream_inbound_at_mono: now_ms()}}
  end

  def handle_info(
        {WebSocket, socket, %Event.Frame{opcode: :pong, data: payload}, ref},
        %{socket: socket} = state
      ) do
    WebSocket.acknowledge(socket, ref)
    state = %{state | last_upstream_inbound_at_mono: now_ms()}

    state =
      case state.upstream_ping do
        %{payload: ^payload, pong_timer: timer} ->
          cancel_timer(timer)
          schedule_upstream_ping(%{state | upstream_ping: nil})

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(
        {WebSocket, socket, %Event.Frame{opcode: :text, data: bytes}, ref},
        %{socket: socket, pending: nil, limits: %{max_message_bytes: limit}} = state
      )
      when is_binary(bytes) and byte_size(bytes) <= limit do
    handle_upstream_text(state, bytes, ref)
  end

  def handle_info(
        {WebSocket, socket, %Event.Message{data: bytes}, ref},
        %{socket: socket, pending: nil, limits: %{max_message_bytes: limit}} = state
      )
      when is_binary(bytes) and byte_size(bytes) <= limit do
    handle_upstream_text(state, bytes, ref)
  end

  def handle_info({WebSocket, socket, %Event.Frame{opcode: :binary}, ref}, %{socket: socket} = state) do
    WebSocket.acknowledge(socket, ref)
    terminal(state, 1003, %{initiator: :upstream, cause: "upstream_protocol_error"})
  end

  def handle_info({WebSocket, socket, %Event.Frame{}, ref}, %{socket: socket} = state) do
    WebSocket.acknowledge(socket, ref)
    terminal(state, 1003, %{initiator: :upstream, cause: "upstream_protocol_error"})
  end

  def handle_info({WebSocket, socket, %Event.Message{}, ref}, %{socket: socket} = state) do
    WebSocket.acknowledge(socket, ref)
    terminal(state, 1003, %{initiator: :upstream, cause: "upstream_protocol_error"})
  end

  def handle_info(
        {WebSocket, socket, %Event.Error{handshake: metadata, reason: reason}},
        %{socket: socket, opening: :pending} = state
      ) do
    code = if reason == :timeout, do: :upstream_timeout, else: :upstream_handshake_failed
    opening_failed(state, code, metadata)
  end

  def handle_info(
        {WebSocket, socket, %Event.Error{reason: reason}},
        %{socket: socket} = state
      ) do
    cause = classify_upstream_error(reason)
    code = if reason in [:frame_too_big, :message_too_big, :read_buffer_too_big], do: 1009, else: 1011
    terminal(state, code, %{initiator: :upstream, cause: cause})
  end

  def handle_info(
        {WebSocket, socket, %Event.Close{code: code}},
        %{socket: socket} = state
      ) do
    terminal(state, close_code(code), %{
      initiator: :upstream,
      cause: "upstream_close",
      upstream_close_code: code
    })
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, :ok}},
        %{socket: socket, upstream_ping: %{send_ref: ref} = ping} = state
      ) do
    {:noreply, %{state | upstream_ping: %{ping | send_ref: nil}}}
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, {:error, _reason}}},
        %{socket: socket, upstream_ping: %{send_ref: ref}} = state
      ) do
    state = cancel_upstream_ping(state)
    terminal(state, 1011, %{initiator: :gateway, cause: "upstream_write_error"})
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, :ok}},
        %{socket: socket, write: %{ref: ref} = write} = state
      ) do
    cancel_timer(write.timer)
    reply_write(state, write.reply_to, :ok)
    state = %{state | write: nil, active_submit: nil}
    {:noreply, pump_submit_queue(state)}
  end

  def handle_info(
        {WebSocket, socket, {:send_result, ref, {:error, _}}},
        %{socket: socket, write: %{ref: ref}} = state
      ) do
    terminal(state, 1011, %{initiator: :gateway, cause: "upstream_write_error"})
  end

  def handle_info({:write_expired, ref}, %{write: %{ref: ref}} = state) do
    terminal(state, 1011, %{initiator: :gateway, cause: "upstream_write_timeout"})
  end

  def handle_info({:delivery_expired, ref}, %{pending: {_bytes, ref}} = state) do
    state =
      state
      |> record_close(%{
        initiator: :gateway,
        cause: "delivery_ack_timeout",
        local_close_code: 1011
      })
      |> cancel_prep_worker()
      |> fail_write()
      |> cancel_upstream_ping()

    {:stop, :normal, state}
  end

  def handle_info(:upstream_ping, %{opening: {:ok, _}, terminal: nil, socket: socket} = state)
      when not is_nil(socket) do
    state = %{state | upstream_ping_timer: nil}

    if state.upstream_ping != nil do
      {:noreply, state}
    else
      payload = :crypto.strong_rand_bytes(8)

      case WebSocket.send_frame_ack(socket, {:ping, payload}) do
        {:ok, send_ref} ->
          timer =
            Process.send_after(
              self(),
              {:upstream_pong_expired, payload},
              state.limits.upstream_pong_timeout_ms
            )

          {:noreply,
           %{state | upstream_ping: %{send_ref: send_ref, payload: payload, pong_timer: timer}}}

        {:error, :send_queue_full} ->
          delay = min(1_000, state.limits.upstream_ping_interval_ms)
          {:noreply, %{state | upstream_ping_timer: Process.send_after(self(), :upstream_ping, delay)}}

        {:error, _reason} ->
          terminal(state, 1011, %{initiator: :gateway, cause: "upstream_write_error"})
      end
    end
  end

  def handle_info(:upstream_ping, state), do: {:noreply, %{state | upstream_ping_timer: nil}}

  def handle_info({:upstream_pong_expired, payload}, %{upstream_ping: %{payload: payload}} = state) do
    state = %{state | upstream_ping: nil}
    terminal(state, 1011, %{initiator: :gateway, cause: "upstream_pong_timeout"})
  end

  def handle_info({:upstream_pong_expired, _payload}, state), do: {:noreply, state}

  def handle_info({:prep_done, worker_ref, result}, %{prep_worker: %{ref: worker_ref} = worker} = state) do
    Process.demonitor(worker.monitor, [:flush])
    cancel_timer(worker.timer)
    state = %{state | prep_worker: nil}
    handle_prep_result(state, worker.kind, result)
  end

  def handle_info({:prep_done, _worker_ref, _result}, state), do: {:noreply, state}

  def handle_info({:prep_expired, worker_ref}, %{prep_worker: %{ref: worker_ref}} = state) do
    state = cancel_prep_worker(state)
    handle_prep_timeout(state)
  end

  def handle_info({:prep_expired, _worker_ref}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{prep_worker: %{monitor: monitor, kind: kind}} = state
      ) do
    cancel_timer(state.prep_worker.timer)
    state = %{state | prep_worker: nil}
    handle_prep_result(state, kind, {:error, :policy_unavailable})
  end

  def handle_info(:opening_expired, %{opening: :pending} = state),
    do: opening_failed(state, :upstream_timeout, nil)

  def handle_info(:attach_expired, %{attached: false} = state) do
    state = record_close(state, %{initiator: :gateway, cause: "attach_timeout", status: 503})
    {:stop, :normal, state}
  end

  def handle_info(:first_create_expired, %{opening: :awaiting_route} = state) do
    state =
      record_close(state, %{
        initiator: :gateway,
        cause: "first_create_timeout",
        local_close_code: 1001
      })

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    # When Gaoxy's max_lifetime expires, ws.deadline is already elapsed so Gaoxy's
    # Admission.begin_callback skips Socket.terminate/2. Detect lifetime expiry here
    # so the close diagnostic still classifies it accurately instead of client_disconnect.
    elapsed = now_ms() - state.started_at_mono

    down_info =
      if is_integer(state.limits.max_lifetime_ms) and
           elapsed >= state.limits.max_lifetime_ms - 50 do
        %{initiator: :gateway, cause: "downstream_lifetime", local_close_code: 1001}
      else
        %{initiator: :client, cause: "client_disconnect"}
      end

    state =
      state
      |> maybe_record_close(down_info)
      |> cancel_prep_worker()
      |> fail_write()
      |> cancel_upstream_ping()

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{socket_monitor: ref} = state),
    do: terminal(state, 1011, %{initiator: :upstream, cause: "upstream_process_down"})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state =
      state
      |> cancel_prep_worker()
      |> cancel_upstream_ping()

    if state.socket && match?({_bytes, _ref}, state.pending) do
      {_bytes, ref} = state.pending
      WebSocket.acknowledge(state.socket, ref)
    end

    cleanup(state.socket, state.limits.cleanup_timeout_ms)
    finalize_session_close(state)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp handle_upstream_text(state, bytes, ref) do
    state = %{
      state
      | pending: {bytes, ref},
        last_upstream_inbound_at_mono: now_ms(),
        response_access: ResponseAccess.observe(state.response_access, bytes)
    }

    state = if state.attached, do: deliver(state), else: state
    {:noreply, state}
  end

  defp start_submit(state, %{ref: submit_ref, bytes: bytes, deadline: deadline} = submit) do
    remaining = remaining_ms(deadline)

    cond do
      remaining <= 0 ->
        handle_unsubmitted_error(state, submit, :submission_expired)

      byte_size(bytes) > state.limits.max_message_bytes ->
        handle_unsubmitted_error(state, submit, :message_too_big)

      state.opening == :awaiting_route ->
        cancel_timer(state.first_create_timer)
        request = state.request
        access = state.access
        codec_options = state.codec_options
        state = %{state | first_create_timer: nil, request: nil, active_submit: Map.put(submit, :phase, :routing)}
        start_worker(state, :route, remaining, fn ->
          ResponsesWebSocket.route_with_params(request, access, bytes, codec_options)
        end)

      match?({:ok, _}, state.opening) ->
        state = %{state | active_submit: Map.put(submit, :phase, :preparing)}
        start_prepare_worker(state, state.active_submit, {:raw, bytes})

      true ->
        notify_submit(state, submit_ref, {:reject_fatal, 1011, "Session unavailable", nil})
        state
    end
  end

  defp start_prepare_worker(state, %{deadline: deadline} = submit, input) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      handle_unsubmitted_error(state, submit, :submission_expired)
    else
      policy = state.policy
      codec_options = state.codec_options
      state = %{state | active_submit: Map.put(submit, :phase, :preparing)}

      start_worker(state, :prepare, remaining, fn ->
        case input do
          {:raw, bytes} ->
            prepare(%{policy: policy, limits: state.limits, codec_options: codec_options}, bytes)

          {:decoded, params} ->
            prepare_decoded(%{policy: policy, codec_options: codec_options}, params)
        end
      end)
    end
  end

  defp start_worker(state, kind, timeout_ms, fun) do
    parent = self()
    worker_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            _ -> {:error, :policy_unavailable}
          catch
            _, _ -> {:error, :policy_unavailable}
          end

        Kernel.send(parent, {:prep_done, worker_ref, result})
      end)

    timer = Process.send_after(self(), {:prep_expired, worker_ref}, max(timeout_ms, 1))
    %{state | prep_worker: %{pid: pid, monitor: monitor, ref: worker_ref, kind: kind, timer: timer}}
  end

  defp cancel_prep_worker(%{prep_worker: nil} = state), do: state

  defp cancel_prep_worker(%{prep_worker: worker} = state) do
    cancel_timer(worker.timer)
    Process.demonitor(worker.monitor, [:flush])
    # Do not forcefully exit the worker mid-Repo checkout; its late {:prep_done, ref, _}
    # reply is ignored once prep_worker is cleared, allowing DB connections to unwind cleanly.
    %{state | prep_worker: nil}
  end

  defp handle_prep_result(%{active_submit: nil} = state, _kind, _result), do: {:noreply, state}

  defp handle_prep_result(state, :route, {:ok, opts, decoded_params}) do
    submit = state.active_submit
    remaining = remaining_ms(submit.deadline)

    if remaining <= 0 or not Process.alive?(state.owner) do
      state =
        record_close(state, %{
          initiator: :gateway,
          cause: "submission_expired",
          status: 408,
          local_close_code: 1011
        })

      notify_submit(state, submit.ref, {:reject_fatal, 1011, "Submission deadline expired", error_event(408, "submission_expired", nil)})
      {:stop, :normal, %{state | active_submit: nil}}
    else
      case open_transport(opts, state, min(state.limits.opening_timeout_ms, remaining)) do
        {:ok, state} ->
          active = submit |> Map.put(:phase, :opening) |> Map.put(:params, decoded_params)
          {:noreply, %{state | active_submit: active}}

        {:stop, reason} ->
          state = record_close(state, %{initiator: :gateway, cause: "invalid_transport_options", status: 503, local_close_code: 1011})
          notify_submit(state, submit.ref, {:reject_fatal, 1011, "Responses connection failed", error_event(503, "responses_websocket_unavailable", nil)})
          {:stop, reason, %{state | active_submit: nil}}
      end
    end
  end

  defp handle_prep_result(state, :route, {:error, {status, code}}) do
    submit = state.active_submit
    close_code = if status >= 500, do: 1011, else: 1008

    state =
      record_close(state, %{
        initiator: :gateway,
        cause: code,
        status: status,
        local_close_code: close_code
      })

    notify_submit(
      state,
      submit.ref,
      {:reject_fatal, close_code, "Responses connection failed", error_event(status, code, nil)}
    )

    {:stop, :normal, %{state | active_submit: nil}}
  end

  defp handle_prep_result(state, :route, _error) do
    handle_prep_result(state, :route, {:error, {503, "responses_websocket_unavailable"}})
  end

  defp handle_prep_result(state, :prepare, {:ok, encoded}) do
    submit = state.active_submit
    remaining = remaining_ms(submit.deadline)

    cond do
      not is_nil(state.terminal) ->
        notify_submit(state, submit.ref, {:reject_fatal, state.terminal, "Session closed", nil})
        {:noreply, %{state | active_submit: nil}}

      not Process.alive?(state.owner) ->
        {:stop, :normal, %{state | active_submit: nil}}

      byte_size(encoded) > state.max_outbound ->
        {:noreply, handle_unsubmitted_error(state, submit, :message_exceeds_peer_limit)}

      remaining <= 0 ->
        {:noreply, handle_unsubmitted_error(state, submit, :submission_expired)}

      true ->
        case admit_upstream_write(state, encoded, remaining, {:submit, submit.ref}) do
          {:noreply, next_state} -> {:noreply, next_state}
          {:stop, reason, {:error, :submission_unknown}, next_state} ->
            notify_submit(
              next_state,
              submit.ref,
              {:reject_fatal, 1011, "Request outcome uncertain; do not replay", nil}
            )

            {:stop, reason, %{next_state | active_submit: nil}}
        end
    end
  end

  defp handle_prep_result(state, :prepare, {:error, reason}) do
    submit = state.active_submit

    if fatal_prepare_error?(reason) do
      {close_code, close_reason, cause} = fatal_error_details(reason)

      state =
        record_close(state, %{
          initiator: :gateway,
          cause: cause,
          local_close_code: close_code
        })

      notify_submit(state, submit.ref, {:reject_fatal, close_code, close_reason, nil})
      {:stop, :normal, %{state | active_submit: nil}}
    else
      {:noreply, handle_unsubmitted_error(state, submit, reason)}
    end
  end

  defp handle_prep_timeout(%{active_submit: nil} = state), do: {:noreply, state}

  defp handle_prep_timeout(%{opening: :awaiting_route, active_submit: submit} = state) do
    state =
      record_close(state, %{
        initiator: :gateway,
        cause: "submission_expired",
        status: 408,
        local_close_code: 1011
      })

    notify_submit(
      state,
      submit.ref,
      {:reject_fatal, 1011, "Submission deadline expired", error_event(408, "submission_expired", nil)}
    )

    {:stop, :normal, %{state | active_submit: nil}}
  end

  defp handle_prep_timeout(%{active_submit: submit} = state) do
    {:noreply, handle_unsubmitted_error(state, submit, :submission_expired)}
  end

  defp handle_unsubmitted_error(state, submit, reason) do
    {status, code} = request_rejection(reason)
    notify_submit(state, submit.ref, {:reject_request, status, code, nil})
    pump_submit_queue(%{state | active_submit: nil})
  end

  defp pump_submit_queue(%{active_submit: nil, terminal: nil} = state) do
    case :queue.out(state.submit_queue) do
      {:empty, _} ->
        state

      {{:value, next}, rest} ->
        start_submit(%{state | submit_queue: rest}, next)
    end
  end

  defp pump_submit_queue(state), do: state

  defp admit_upstream_write(state, encoded, remaining_ms, reply_to) do
    case WebSocket.send_frame_ack(state.socket, {:text, encoded}) do
      {:ok, ref} ->
        write_budget = min(state.limits.write_timeout_ms, remaining_ms)
        timer = Process.send_after(self(), {:write_expired, ref}, max(write_budget, 1) + 100)
        {:noreply, %{state | write: %{ref: ref, reply_to: reply_to, timer: timer}}}

      {:error, _} ->
        # Even a local call timeout can race transport admission. Never invite
        # a retry based on an unobservable submission boundary.
        state = record_close(state, %{initiator: :gateway, cause: "upstream_write_error", local_close_code: 1011})
        {:stop, :normal, {:error, :submission_unknown}, state}
    end
  end

  defp check_outbound_size(encoded, max_outbound) do
    if byte_size(encoded) <= max_outbound, do: :ok, else: {:error, :message_exceeds_peer_limit}
  end

  defp fatal_prepare_error?(reason)
       when reason in [:principal_changed, :route_changed, :credential_refreshed, :policy_unavailable],
       do: true

  defp fatal_prepare_error?(_), do: false

  defp fatal_error_details(:principal_changed),
    do: {1008, "Principal authorization changed", "principal_changed"}

  defp fatal_error_details(:credential_refreshed),
    do: {1008, "Credential refreshed; reconnect required", "credential_refreshed"}

  defp fatal_error_details(:route_changed),
    do: {1008, "Responses route changed", "route_changed"}

  defp fatal_error_details(:policy_unavailable),
    do: {1011, "Request outcome uncertain; do not replay", "policy_unavailable"}

  defp request_rejection(:rate_limited), do: {429, "rate_limited"}
  defp request_rejection(:model_mismatch), do: {400, "model_mismatch"}
  defp request_rejection(:invalid_model), do: {400, "invalid_model"}
  defp request_rejection(:invalid_request), do: {400, "invalid_request"}
  defp request_rejection(:message_too_big), do: {413, "message_too_big"}
  defp request_rejection(:message_exceeds_peer_limit), do: {413, "message_exceeds_peer_limit"}
  defp request_rejection(:submission_expired), do: {408, "submission_expired"}
  defp request_rejection(_), do: {400, "invalid_request"}

  defp error_event(status, code, metadata) do
    event = %{type: "error", status: status, error: %{code: code, message: code}}

    with %{headers: headers} <- metadata,
         retry_after when is_binary(retry_after) and byte_size(retry_after) <= 128 <-
           HTTP.Headers.get(headers, "retry-after") do
      Map.put(event, :headers, %{"retry-after" => retry_after})
    else
      _ -> event
    end
  end

  defp prepare(state, bytes) do
    if byte_size(bytes) <= state.limits.max_message_bytes,
      do: Policy.prepare(state.policy, bytes, state.codec_options),
      else: {:error, :message_too_big}
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  defp prepare_decoded(state, params) do
    Policy.prepare_decoded(state.policy, params, state.codec_options)
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  defp opening_failed(state, code, metadata) do
    cancel_timer(state.opening_timer)
    log_open(state, {:error, metadata})
    cleanup(state.socket, state.limits.cleanup_timeout_ms)
    {status, error_code} = ResponsesWebSocket.upstream_error(metadata)
    close_code = if status >= 500, do: 1011, else: 1008

    cause =
      case code do
        :upstream_timeout -> "upstream_handshake_timeout"
        :invalid_peer_message_limit -> "invalid_peer_message_limit"
        :invalid_handshake_metadata -> "invalid_handshake_metadata"
        :upstream_closed -> "upstream_closed_during_handshake"
        _ -> "upstream_handshake_failed"
      end

    state =
      record_close(state, %{
        initiator: :upstream,
        cause: cause,
        status: status,
        local_close_code: close_code
      })

    result = {:error, code, metadata}

    cond do
      state.waiter ->
        GenServer.reply(state.waiter, result)
        {:stop, :normal, %{state | waiter: nil, access: nil, opening_timer: nil}}

      match?(%{phase: :opening}, state.active_submit) ->
        submit = state.active_submit

        notify_submit(
          state,
          submit.ref,
          {:reject_fatal, close_code, "Responses connection failed",
           error_event(status, error_code, metadata)}
        )

        {:stop, :normal, %{state | active_submit: nil, access: nil, opening_timer: nil}}

      true ->
        timer = Process.send_after(self(), :attach_expired, state.limits.attach_timeout_ms)
        {:noreply, %{state | opening: result, opening_timer: nil, attach_timer: timer, access: nil}}
    end
  end

  defp log_open(%{access: nil}, _result), do: :ok

  defp log_open(state, {:ok, _metadata}) do
    AccessEvent.finalize(
      state.access,
      %Plug.Conn{status: 101, remote_ip: state.remote_ip},
      :success
    )
  end

  defp log_open(state, {:error, metadata}) do
    {status, code} = ResponsesWebSocket.upstream_error(metadata)

    AccessEvent.finalize(
      state.access,
      %Plug.Conn{status: status, remote_ip: state.remote_ip},
      :error,
      error_kind: :transport,
      error_code: code
    )
  end

  defp terminal(%{opening: :pending} = state, _code, _info),
    do: opening_failed(state, :upstream_closed, nil)

  defp terminal(state, code, info) do
    state =
      state
      |> cancel_upstream_ping()
      |> cancel_prep_worker()
      |> maybe_record_close(Map.put_new(info, :local_close_code, code))
      |> fail_write()
      |> Map.put(:terminal, state.terminal || code)
      |> notify_terminal()

    {:noreply, state}
  end

  defp fail_write(%{write: nil} = state), do: state

  defp fail_write(%{write: write} = state) do
    cancel_timer(write.timer)
    reply_write(state, write.reply_to, {:error, :submission_unknown})
    %{state | write: nil, active_submit: nil}
  end

  defp reply_write(_state, {:call, from}, result), do: GenServer.reply(from, result)

  defp reply_write(state, {:submit, submit_ref}, :ok),
    do: notify_submit(state, submit_ref, :ok)

  defp reply_write(state, {:submit, submit_ref}, {:error, :submission_unknown}),
    do:
      notify_submit(
        state,
        submit_ref,
        {:reject_fatal, 1011, "Request outcome uncertain; do not replay", nil}
      )

  defp notify_submit(%{attached: true, owner: owner}, submit_ref, result) do
    Kernel.send(owner, {:responses_submit_result, self(), submit_ref, result})
  end

  defp notify_submit(_state, _submit_ref, _result), do: :ok

  defp deliver(%{pending: {bytes, ref}} = state) do
    Kernel.send(state.owner, {:responses_event, self(), bytes, ref})

    %{
      state
      | pending_timer:
          Process.send_after(self(), {:delivery_expired, ref}, state.limits.delivery_ack_timeout_ms)
    }
  end

  defp notify_terminal(%{attached: true, pending: nil, terminal: code} = state)
       when is_integer(code) do
    Kernel.send(state.owner, {:responses_closed, self(), code})
    state
  end

  defp notify_terminal(state), do: state

  defp schedule_upstream_ping(%{limits: %{upstream_ping_interval_ms: :infinity}} = state),
    do: state

  defp schedule_upstream_ping(%{limits: %{upstream_ping_interval_ms: interval}} = state)
       when is_integer(interval) and interval > 0 do
    cancel_timer(state.upstream_ping_timer)
    %{state | upstream_ping_timer: Process.send_after(self(), :upstream_ping, interval)}
  end

  defp cancel_upstream_ping(state) do
    cancel_timer(state.upstream_ping_timer)
    if state.upstream_ping, do: cancel_timer(state.upstream_ping.pong_timer)
    %{state | upstream_ping_timer: nil, upstream_ping: nil}
  end

  defp record_close(state, info) when is_map(info) do
    %{state | close_info: Map.merge(%{phase: phase(state)}, info)}
  end

  defp maybe_record_close(state, nil), do: state

  defp maybe_record_close(%{close_info: nil} = state, info) when is_map(info),
    do: record_close(state, info)

  defp maybe_record_close(%{close_info: existing} = state, info) when is_map(info) do
    # Preserve the primary cause already recorded while filling any missing close codes.
    merged =
      existing
      |> Map.put_new(:local_close_code, info[:local_close_code])
      |> Map.put_new(:upstream_close_code, info[:upstream_close_code])

    %{state | close_info: merged}
  end

  defp finalize_session_close(%{close_logged?: true} = state), do: state

  defp finalize_session_close(state) do
    now = now_ms()
    base_info = state.close_info || %{phase: phase(state), initiator: :gateway, cause: "session_closed"}

    {response_access, interrupted_count} =
      ResponseAccess.finalize_interrupted(state.response_access, base_info)

    close_info =
      base_info
      |> Map.put_new(:phase, phase(state))
      |> Map.put_new(:status, default_close_status(state))
      |> Map.put(:duration_ms, max(now - state.started_at_mono, 0))
      |> Map.put(:last_inbound_age_ms, age_ms(now, state.last_inbound_at_mono))
      |> Map.put(:last_outbound_age_ms, age_ms(now, state.last_outbound_at_mono))
      |> Map.put(:last_upstream_inbound_age_ms, age_ms(now, state.last_upstream_inbound_at_mono))
      |> Map.put(:interrupted_responses, interrupted_count)

    ResponseAccess.finalize_close(state.close_access, state.remote_ip, close_info)
    %{state | response_access: response_access, close_logged?: true}
  end

  defp phase(%{attached: false}), do: "awaiting_attach"
  defp phase(%{opening: :awaiting_route}), do: "awaiting_first_create"
  defp phase(%{opening: :pending}), do: "opening_upstream"
  defp phase(%{terminal: code}) when is_integer(code), do: "closing"
  defp phase(%{opening: {:ok, _}}), do: "open"
  defp phase(_), do: "closing"

  defp default_close_status(%{opening: {:ok, _}}), do: 101
  defp default_close_status(%{opening: {:error, _, %{status: status}}}) when is_integer(status), do: status
  defp default_close_status(%{opening: :awaiting_route}), do: 101
  defp default_close_status(_), do: 502

  defp classify_upstream_error(:idle_timeout), do: "upstream_idle_timeout"
  defp classify_upstream_error(:send_timeout), do: "upstream_write_timeout"
  defp classify_upstream_error(:frame_too_big), do: "upstream_frame_too_big"
  defp classify_upstream_error(:message_too_big), do: "upstream_message_too_big"
  defp classify_upstream_error(:read_buffer_too_big), do: "upstream_read_buffer_too_big"
  defp classify_upstream_error(:consumer_overloaded), do: "upstream_consumer_overloaded"
  defp classify_upstream_error(_), do: "upstream_transport_error"

  defp close_code(code) when code in [1000, 1001, 1008, 1009, 1011, 1012, 1013], do: code
  defp close_code(_), do: 1011

  defp cleanup(nil, _timeout), do: :ok

  defp cleanup(socket, timeout) do
    WebSocket.close(socket)
    ClientCompletion.await(WebSocket.completion(socket), timeout)
  end

  defp safe_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp call_timeout, do: Limits.current().submission_timeout_ms
  defp cleanup_call_timeout, do: Limits.current().cleanup_timeout_ms + 2_000
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining_ms(deadline), do: max(deadline - now_ms(), 0)
  defp age_ms(_now, nil), do: nil
  defp age_ms(now, ts), do: max(now - ts, 0)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
