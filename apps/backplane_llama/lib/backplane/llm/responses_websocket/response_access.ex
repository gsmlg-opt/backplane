defmodule Backplane.LLM.ResponsesWebSocket.ResponseAccess do
  @moduledoc false

  alias Backplane.AiProtocol.{OpenAIResponsesObserver, Serialization}
  alias Backplane.LLM.AccessEvent
  alias Backplane.LLM.ResponsesWebSocket.Frame
  alias Backplane.Observability.Id

  @terminal_types ~w(response.completed response.incomplete response.failed)
  @observed_types ["response.created" | @terminal_types]
  @max_counter 2_147_483_647

  defstruct [:access, :remote_ip, :limits, ids: %{}, finished: :queue.new()]

  def new(access, remote_ip, limits),
    do: %__MODULE__{access: access, remote_ip: remote_ip, limits: limits}

  def observed?(nil, _id), do: false
  def observed?(%__MODULE__{ids: ids}, id), do: is_map_key(ids, id)

  def stream_id(nil, _id), do: nil

  def stream_id(%__MODULE__{ids: ids}, id) do
    {_status, lane} = Map.get(ids, id, {nil, nil})
    lane
  end

  def observe(nil, _bytes), do: nil

  def observe(%__MODULE__{limits: limits} = state, bytes) when is_binary(bytes) do
    if :binary.match(bytes, @observed_types) == :nomatch do
      state
    else
      case Serialization.from_json(bytes, max_encoded_bytes: limits.max_message_bytes) do
        {:ok, %{"type" => type, "response" => %{"id" => id}} = event}
        when type in @observed_types and is_binary(id) and
               byte_size(id) in 1..128 ->
          if Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, id) do
            observe_event(state, :binary.copy(id), type, event)
          else
            state
          end

        _ ->
          state
      end
    end
  rescue
    _ -> state
  end

  @doc """
  Marks every observed in-progress `response.created` ID as transport-interrupted
  without inventing a provider terminal state, cancellation, or zero token usage.
  """
  def finalize_interrupted(nil, _close_info), do: {nil, 0}

  def finalize_interrupted(%__MODULE__{} = state, close_info) do
    Enum.reduce(state.ids, {state, 0}, fn
      {id, {started_at, lane}}, {acc, count} when is_integer(started_at) ->
        emit_interrupted(state.access, state.remote_ip, started_at, id, close_info)
        {put_finished(acc, id, lane), count + 1}

      _entry, acc ->
        acc
    end)
  rescue
    _ -> {state, 0}
  end

  @doc """
  Emits one bounded, sanitized connection-end access record for a Responses WS session.
  """
  def finalize_close(nil, _remote_ip, _close_info), do: :ok

  def finalize_close(%AccessEvent{} = access, remote_ip, close_info) when is_map(close_info) do
    initiator = safe_label(close_info[:initiator]) || "gateway"
    cause = safe_label(close_info[:cause]) || "connection_closed"
    phase = safe_label(close_info[:phase]) || "open"
    interrupted = non_neg_int(close_info[:interrupted_responses]) || 0
    local_code = close_code(close_info[:local_close_code])
    upstream_code = close_code(close_info[:upstream_close_code])
    status = valid_status(close_info[:status]) || 101

    outcome = close_outcome(initiator, cause, local_code, upstream_code, interrupted, status)

    {error_kind, error_code, error_reason} =
      case outcome do
        :success ->
          {nil, nil, nil}

        :cancelled ->
          {"client_disconnect", cause, cause}

        :error ->
          {close_error_kind(cause), cause, cause}
      end

    duration_ms =
      non_neg_int(close_info[:duration_ms]) ||
        max(System.monotonic_time(:millisecond) - (access.started_at_mono || 0), 0)

    ws_metadata =
      %{
        phase: phase,
        initiator: initiator,
        cause: cause,
        duration_ms: duration_ms,
        interrupted_responses: interrupted
      }
      |> maybe_put(:last_inbound_age_ms, non_neg_int(close_info[:last_inbound_age_ms]))
      |> maybe_put(:last_outbound_age_ms, non_neg_int(close_info[:last_outbound_age_ms]))
      |> maybe_put(
        :last_upstream_inbound_age_ms,
        non_neg_int(close_info[:last_upstream_inbound_age_ms])
      )
      |> maybe_put(:local_close_code, local_code)
      |> maybe_put(:upstream_close_code, upstream_code)

    close_access = %{
      access
      | event_id: Id.generator().event_id(),
        operation: "responses.websocket.close",
        request_bytes: nil
    }

    conn = %Plug.Conn{status: status, remote_ip: remote_ip || {0, 0, 0, 0}}

    opts =
      [
        status: status,
        observed_usage: %{
          input_tokens: nil,
          output_tokens: nil,
          cached_tokens: nil,
          reasoning_tokens: nil,
          total_tokens: nil,
          provider_request_id: nil,
          finish_reason: nil,
          protocol_terminal: nil,
          error_code: nil,
          error_type: nil,
          metadata: %{
            observation: %{unavailable: true},
            websocket_close: ws_metadata
          },
          ttft_ms: nil,
          stream_duration_ms: nil,
          stream_chunks: nil
        }
      ]
      |> maybe_kw(:error_kind, error_kind)
      |> maybe_kw(:error_code, error_code)
      |> maybe_kw(:error_reason, error_reason)

    AccessEvent.finalize(close_access, conn, outcome, opts)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe_event(
         %{ids: ids, limits: %{max_response_ids: max_response_ids}} = state,
         id,
         "response.created",
         event
       )
       when map_size(ids) >= max_response_ids and not is_map_key(ids, id) do
    case :queue.out(state.finished) do
      {{:value, oldest}, finished} ->
        state = %{state | ids: Map.delete(ids, oldest), finished: finished}
        put_created(state, id, event)

      {:empty, _finished} ->
        state
    end
  end

  defp observe_event(state, id, "response.created", event), do: put_created(state, id, event)

  defp observe_event(
         %{ids: ids, limits: %{max_response_ids: max_response_ids}} = state,
         id,
         _type,
         _event
       )
       when map_size(ids) >= max_response_ids and not is_map_key(ids, id),
       do: state

  defp observe_event(state, id, _type, event) do
    case Map.get(state.ids, id, {nil, nil}) do
      {:finished, _lane} ->
        state

      {started_at, lane} ->
        facts = OpenAIResponsesObserver.observe_terminal_event(event)
        finalize(state.access, state.remote_ip, started_at, id, facts)
        put_finished(state, id, lane || Frame.stream_id(event["stream_id"]))
    end
  end

  defp put_created(state, id, event) do
    ids =
      Map.put_new_lazy(state.ids, id, fn ->
        {System.monotonic_time(:millisecond), Frame.stream_id(event["stream_id"])}
      end)

    %{state | ids: ids}
  end

  defp put_finished(state, id, lane) do
    %{
      state
      | ids: Map.put(state.ids, id, {:finished, lane}),
        finished: :queue.in(id, state.finished)
    }
  end

  defp finalize(nil, _remote_ip, _started_at, _id, _facts), do: :ok

  defp finalize(access, remote_ip, started_at, id, facts) do
    access = %{
      access
      | event_id: Id.generator().event_id(),
        operation: "responses.websocket.create",
        started_at_mono: started_at,
        upstream_started_at_mono: started_at,
        request_bytes: nil
    }

    usage = usage(facts, id)
    conn = %Plug.Conn{status: 101, remote_ip: remote_ip}

    if facts.protocol_terminal == :incomplete and facts.finish_reason != "steered" do
      AccessEvent.finalize(access, conn, :error,
        error_kind: :upstream_error,
        error_code: "responses_incomplete",
        observed_usage: usage
      )
    else
      # AccessEvent classifies a failed protocol terminal as an upstream error.
      AccessEvent.finalize(access, conn, :success, observed_usage: usage)
    end
  end

  defp emit_interrupted(nil, _remote_ip, _started_at, _id, _close_info), do: :ok

  defp emit_interrupted(access, remote_ip, started_at, id, close_info) do
    initiator = safe_label(close_info[:initiator]) || "gateway"
    cause = safe_label(close_info[:cause]) || "transport_interrupted"
    outcome = if initiator == "client", do: :cancelled, else: :error
    error_kind = if initiator == "client", do: "client_disconnect", else: "transport_interrupted"

    interrupted_access = %{
      access
      | event_id: Id.generator().event_id(),
        operation: "responses.websocket.create",
        started_at_mono: started_at,
        upstream_started_at_mono: started_at,
        request_bytes: nil
    }

    usage = %{
      input_tokens: nil,
      output_tokens: nil,
      cached_tokens: nil,
      reasoning_tokens: nil,
      total_tokens: nil,
      provider_request_id: id,
      finish_reason: nil,
      protocol_terminal: nil,
      error_code: nil,
      error_type: nil,
      metadata: %{
        protocol_observation: %{
          observation_status: :incomplete,
          protocol_terminal: nil,
          usage_status: :unknown,
          transport_interrupted: true,
          close_cause: cause
        }
      },
      ttft_ms: nil,
      stream_duration_ms: nil,
      stream_chunks: nil
    }

    AccessEvent.finalize(
      interrupted_access,
      %Plug.Conn{status: 101, remote_ip: remote_ip || {0, 0, 0, 0}},
      outcome,
      error_kind: error_kind,
      error_code: "responses_interrupted",
      error_reason: cause,
      observed_usage: usage
    )
  end

  defp close_outcome(initiator, cause, local_code, upstream_code, interrupted, status) do
    cond do
      status != 101 ->
        :error

      cause == "client_close" and local_code in [nil, 1000, 1001] and interrupted == 0 ->
        :success

      cause == "upstream_close" and upstream_code in [nil, 1000, 1001] and interrupted == 0 ->
        :success

      initiator == "client" ->
        :cancelled

      true ->
        :error
    end
  end

  defp close_error_kind(cause) do
    cond do
      cause in [
        "downstream_read_idle",
        "downstream_pong_timeout",
        "downstream_lifetime",
        "downstream_callback_timeout",
        "attach_timeout",
        "first_create_timeout",
        "upstream_handshake_timeout",
        "upstream_pong_timeout",
        "upstream_receive_backpressure_timeout",
        "upstream_idle_timeout",
        "upstream_write_timeout",
        "delivery_ack_timeout",
        "submission_expired"
      ] ->
        "timeout"

      cause in [
        "policy_rejected",
        "principal_changed",
        "route_changed",
        "credential_refreshed",
        "invalid_request",
        "invalid_model",
        "model_unavailable",
        "responses_websocket_disabled"
      ] ->
        "policy"

      cause in ["downstream_resource_limit", "mailbox_limit"] ->
        "resource_limit"

      true ->
        "transport"
    end
  end

  defp usage(facts, id) do
    input = counter(facts.input_tokens)
    output = counter(facts.output_tokens)
    cached = counter(facts.cached_tokens)
    reasoning = counter(facts.reasoning_tokens)
    total = counter(facts.native_total) || sum(input, output)

    usage_status =
      cond do
        is_integer(input) and is_integer(output) -> facts.usage_status
        Enum.any?([input, output, cached, reasoning, total], &is_integer/1) -> :partial
        true -> :unknown
      end

    %{
      input_tokens: input,
      output_tokens: output,
      cached_tokens: cached,
      reasoning_tokens: reasoning,
      total_tokens: total,
      provider_request_id: id,
      finish_reason: facts.finish_reason,
      protocol_terminal: facts.protocol_terminal,
      error_code: facts.error_code,
      error_type: facts.error_type,
      metadata: %{
        protocol_observation: %{
          observation_status: facts.observation_status,
          protocol_terminal: facts.protocol_terminal,
          usage_status: usage_status
        }
      },
      ttft_ms: nil,
      stream_duration_ms: nil,
      stream_chunks: nil
    }
  end

  defp counter(value) when is_integer(value) and value in 0..@max_counter, do: value
  defp counter(_), do: nil

  defp sum(input, output) when is_integer(input) and is_integer(output),
    do: counter(input + output)

  defp sum(_, _), do: nil

  defp safe_label(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> safe_label()

  defp safe_label(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.match?(value, ~r/\A[a-z0-9_.-]+\z/), do: value
  end

  defp safe_label(_), do: nil

  defp non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_), do: nil

  defp close_code(code) when is_integer(code) and code in 1000..4999, do: code
  defp close_code(_), do: nil

  defp valid_status(status) when is_integer(status) and status in 100..599, do: status
  defp valid_status(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_kw(opts, _key, nil), do: opts
  defp maybe_kw(opts, key, value), do: Keyword.put(opts, key, value)
end
