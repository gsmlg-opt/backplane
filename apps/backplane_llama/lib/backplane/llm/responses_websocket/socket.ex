defmodule Backplane.LLM.ResponsesWebSocket.Socket do
  @moduledoc """
  Native JSON text-message downstream for a caller-owned Responses session.

  Ping/pong are hop-local. The gateway initiates periodic Ping frames downstream
  and tracks Pong replies so output-only streams, reasoning pauses, and tool waits
  remain alive while genuinely unresponsive peers are closed within bounded time.
  No application interrupt or cancellation is inferred from a Close frame or
  downstream disconnect.
  """

  @behaviour WebSock
  alias Backplane.LLM.ResponsesWebSocket.{Frame, Limits, Session}

  @impl true
  def init(%{session: session, limits: limits}) do
    do_init(session, limits)
  end

  def init(session) when is_pid(session) do
    do_init(session, Limits.current())
  end

  defp do_init(session, limits) do
    state = %{
      session: session,
      limits: limits,
      monitor: Process.monitor(session),
      connected_at_mono: System.monotonic_time(:millisecond),
      ping_timer: nil,
      pending_ping: nil,
      client_closed?: false,
      client_close_code: nil,
      close_info: nil
    }

    case Session.attach(session, self()) do
      :ok ->
        {:ok, schedule_ping(state)}

      _ ->
        {:stop, :normal, {1011, "Session unavailable"},
         %{state | close_info: %{initiator: :gateway, cause: "attach_failed", local_close_code: 1011}}}
    end
  end

  @impl true
  def handle_in({bytes, opcode: :text}, state) do
    deadline = System.monotonic_time(:millisecond) + state.limits.submission_timeout_ms
    submit_ref = make_ref()
    Session.submit(state.session, submit_ref, bytes, deadline)
    {:ok, state}
  end

  def handle_in(_message, state) do
    close_info = %{initiator: :client, cause: "downstream_protocol_error", local_close_code: 1003}
    {:stop, :normal, {1003, "JSON text messages required"}, %{state | close_info: close_info}}
  end

  @doc false
  def gaoxy_close({code, _reason}, state) do
    {:ok, %{state | client_closed?: true, client_close_code: code}}
  end

  @impl true
  def handle_info({:responses_submit_result, session, _submit_ref, :ok}, %{session: session} = state),
    do: {:ok, state}

  def handle_info(
        {:responses_submit_result, session, _submit_ref, {:reject_request, status, code, metadata}},
        %{session: session} = state
      ) do
    event = Frame.error_event(status, code, metadata)
    Session.note_activity(session, :outbound)
    {:push, {:text, Formata.JSON.encode!(event)}, state}
  end

  def handle_info(
        {:responses_submit_result, session, _submit_ref,
         {:reject_fatal, close_code, close_reason, nil}},
        %{session: session} = state
      ) do
    {:stop, :normal, {close_code, close_reason}, state}
  end

  def handle_info(
        {:responses_submit_result, session, _submit_ref,
         {:reject_fatal, close_code, close_reason, event}},
        %{session: session} = state
      ) do
    {:stop, :normal, {close_code, close_reason}, {:text, Formata.JSON.encode!(event)}, state}
  end

  def handle_info({:responses_event, session, bytes, ref}, %{session: session} = state) do
    # Gaoxy completes the synchronous push before dispatching this next message.
    # If its write fails, terminate closes the session without releasing credit.
    Kernel.send(self(), {:responses_ack, session, ref})
    {:push, {:text, bytes}, state}
  end

  def handle_info({:responses_ack, session, ref}, %{session: session} = state) do
    Session.ack(session, ref)
    {:ok, state}
  end

  def handle_info(:downstream_ping, state) do
    state = %{state | ping_timer: nil}

    if state.pending_ping != nil do
      {:ok, state}
    else
      payload = :crypto.strong_rand_bytes(8)

      pong_timer =
        Process.send_after(
          self(),
          {:downstream_pong_expired, payload},
          state.limits.downstream_pong_timeout_ms
        )

      {:push, {:ping, payload}, %{state | pending_ping: %{payload: payload, timer: pong_timer}}}
    end
  end

  def handle_info({:downstream_pong_expired, payload}, %{pending_ping: %{payload: payload}} = state) do
    close_info = %{initiator: :gateway, cause: "downstream_pong_timeout", local_close_code: 1001}

    {:stop, :normal, {1001, "Client ping timeout"},
     %{state | pending_ping: nil, close_info: close_info}}
  end

  def handle_info({:downstream_pong_expired, _payload}, state), do: {:ok, state}

  def handle_info({:responses_closed, session, code}, %{session: session} = state),
    do: {:stop, :normal, {code, ""}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    close_info = %{initiator: :gateway, cause: "session_down", local_close_code: 1011}
    {:stop, :normal, {1011, "Upstream unavailable"}, %{state | close_info: close_info}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_control({payload, opcode: :pong}, state) do
    Session.note_activity(state.session, :inbound)

    state =
      case state.pending_ping do
        %{payload: ^payload, timer: timer} ->
          Process.cancel_timer(timer)
          schedule_ping(%{state | pending_ping: nil})

        _ ->
          state
      end

    {:ok, state}
  end

  def handle_control({_payload, opcode: :ping}, state) do
    Session.note_activity(state.session, :inbound)
    {:ok, state}
  end

  def handle_control(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    cancel_ping_timers(state)
    close_info = state.close_info || classify_terminate(reason, state)
    Session.close(state.session, close_info)
    :ok
  end

  defp schedule_ping(%{limits: %{downstream_ping_interval_ms: :infinity}} = state), do: state

  defp schedule_ping(%{limits: %{downstream_ping_interval_ms: interval}} = state)
       when is_integer(interval) and interval > 0 do
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    %{state | ping_timer: Process.send_after(self(), :downstream_ping, interval)}
  end

  defp cancel_ping_timers(state) do
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    if state.pending_ping, do: Process.cancel_timer(state.pending_ping.timer)
    :ok
  end

  defp classify_terminate(:timeout, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.connected_at_mono

    lifetime_expired? =
      is_integer(state.limits.max_lifetime_ms) and
        (state.limits.downstream_read_timeout_ms == :infinity or
           elapsed >= state.limits.max_lifetime_ms - 50)

    cause = if lifetime_expired?, do: "downstream_lifetime", else: "downstream_read_idle"
    %{initiator: :gateway, cause: cause, local_close_code: 1001}
  end

  defp classify_terminate(:remote, %{client_closed?: true, client_close_code: code}) do
    %{initiator: :client, cause: "client_close", local_close_code: code}
  end

  defp classify_terminate(:remote, _state) do
    %{initiator: :client, cause: "client_disconnect"}
  end

  defp classify_terminate(:shutdown, _state) do
    %{initiator: :shutdown, cause: "server_shutdown", local_close_code: 1001}
  end

  defp classify_terminate({:error, :mailbox_limit}, _state) do
    %{initiator: :gateway, cause: "mailbox_limit", local_close_code: 1009}
  end

  defp classify_terminate({:error, reason}, _state)
       when reason in [:resource_limit, :byte_limit, :message_limit, :fragment_limit, :output_limit] do
    %{initiator: :gateway, cause: "downstream_resource_limit", local_close_code: 1009}
  end

  defp classify_terminate({:error, reason}, _state)
       when reason in [:invalid_utf8, :fragment_order, :protocol_error] do
    %{initiator: :client, cause: "downstream_protocol_error", local_close_code: 1002}
  end

  defp classify_terminate({:error, :deadline_exceeded}, _state) do
    %{initiator: :gateway, cause: "downstream_callback_timeout", local_close_code: 1011}
  end

  defp classify_terminate({:error, _reason}, _state) do
    %{initiator: :gateway, cause: "downstream_write_error", local_close_code: 1011}
  end

  defp classify_terminate(:normal, _state) do
    nil
  end

  defp classify_terminate(_reason, _state) do
    %{initiator: :gateway, cause: "downstream_transport_error", local_close_code: 1011}
  end
end
