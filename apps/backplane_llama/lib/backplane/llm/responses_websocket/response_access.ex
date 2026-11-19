defmodule Backplane.LLM.ResponsesWebSocket.ResponseAccess do
  @moduledoc false

  alias Backplane.AiProtocol.{OpenAIResponsesObserver, Serialization}
  alias Backplane.LLM.AccessEvent
  alias Backplane.Observability.Id

  @terminal_types ~w(response.completed response.incomplete response.failed)
  @max_counter 2_147_483_647

  def new(nil, _remote_ip, _limits), do: nil
  def new(%AccessEvent{} = access, remote_ip, limits), do: {access, remote_ip, %{}, limits}

  def observe(nil, _bytes), do: nil

  def observe({access, remote_ip, ids, limits} = state, bytes) do
    case Serialization.from_json(bytes, max_encoded_bytes: limits.max_message_bytes) do
      {:ok, %{"type" => type, "response" => %{"id" => id}} = event}
      when type in ["response.created" | @terminal_types] and is_binary(id) and
             byte_size(id) in 1..128 ->
        if Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, id) do
          {access, remote_ip,
           observe_event(
             access,
             remote_ip,
             ids,
             :binary.copy(id),
             type,
             event,
             limits.max_response_ids
           ), limits}
        else
          state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp observe_event(_access, _remote_ip, ids, id, _type, _event, max_response_ids)
       when map_size(ids) >= max_response_ids and not is_map_key(ids, id),
       do: ids

  defp observe_event(_access, _remote_ip, ids, id, "response.created", _event, _max_response_ids),
    do: Map.put_new_lazy(ids, id, fn -> System.monotonic_time(:millisecond) end)

  defp observe_event(access, remote_ip, ids, id, _type, event, _max_response_ids) do
    case Map.get(ids, id) do
      :finished ->
        ids

      started_at ->
        facts = OpenAIResponsesObserver.observe_terminal_event(event)
        finalize(access, remote_ip, started_at, id, facts)
        Map.put(ids, id, :finished)
    end
  end

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

    if facts.protocol_terminal == :incomplete do
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
end
