defmodule Backplane.AiProtocol.GoogleGenerateContentObserver do
  @moduledoc """
  Bounded observer for native Google GenerateContent JSON and SSE responses.

  The observer extracts sanitized facts only. It never rewrites or validates the
  response being forwarded by a transport.
  """

  alias Backplane.AiProtocol.{Error, SSE, Serialization}

  @default_max_total_bytes 8_388_608
  @default_max_frame_bytes 1_048_576
  @default_max_buffer_bytes 2_097_152
  @default_max_events 10_000
  @default_max_parse_time_us 250_000
  @default_max_diagnostics 32
  @feed_slice_bytes 65_536
  @diagnostics_truncated "diagnostics_truncated"
  @success_finish_reasons ~w(STOP)
  @partial_finish_reasons ~w(MAX_TOKENS SAFETY RECITATION LANGUAGE OTHER BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_OTHER NO_IMAGE)
  @usage_counters %{
    "promptTokenCount" => :prompt_token_count,
    "candidatesTokenCount" => :candidates_token_count,
    "cachedContentTokenCount" => :cached_content_token_count,
    "thoughtsTokenCount" => :thoughts_token_count,
    "toolUsePromptTokenCount" => :tool_use_prompt_token_count,
    "totalTokenCount" => :total_token_count
  }
  @usage_details %{
    "promptTokensDetails" => :prompt_tokens_details,
    "candidatesTokensDetails" => :candidates_tokens_details,
    "cacheTokensDetails" => :cache_tokens_details,
    "toolUsePromptTokensDetails" => :tool_use_prompt_tokens_details
  }

  defstruct framer: nil,
            operation: :generate,
            max_total_bytes: @default_max_total_bytes,
            max_events: @default_max_events,
            max_parse_time_us: @default_max_parse_time_us,
            max_diagnostics: @default_max_diagnostics,
            bytes_seen: 0,
            events_seen: 0,
            parse_time_us: 0,
            parse_budget_exhausted: false,
            input_truncated: false,
            observation_status: :complete,
            protocol_terminal: nil,
            transport_terminal: nil,
            content_seen: false,
            content_finished: false,
            usage_status: :unknown,
            input_tokens: nil,
            output_tokens: nil,
            cached_tokens: nil,
            reasoning_tokens: nil,
            native_total: nil,
            native_usage: %{},
            count_tokens_total: nil,
            provider_request_id: nil,
            finish_reasons: %{},
            candidates_seen: MapSet.new(),
            blocked: false,
            block_reason: nil,
            partial: false,
            error_code: nil,
            error_type: nil,
            diagnostics: [],
            diagnostics_truncated: false

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      framer:
        opts
        |> Keyword.put_new(:max_frame_bytes, @default_max_frame_bytes)
        |> Keyword.put_new(:max_buffer_bytes, @default_max_buffer_bytes)
        |> SSE.new(),
      operation: normalize_operation(Keyword.get(opts, :operation, :generate)),
      max_total_bytes:
        positive_limit(Keyword.get(opts, :max_total_bytes), @default_max_total_bytes),
      max_events: positive_limit(Keyword.get(opts, :max_events), @default_max_events),
      max_parse_time_us:
        positive_limit(Keyword.get(opts, :max_parse_time_us), @default_max_parse_time_us),
      max_diagnostics:
        positive_limit(Keyword.get(opts, :max_diagnostics), @default_max_diagnostics)
    }
  end

  @spec feed(t(), term()) :: t()
  def feed(%__MODULE__{input_truncated: true} = state, _chunk), do: state

  def feed(%__MODULE__{parse_budget_exhausted: true} = state, chunk) when is_binary(chunk) do
    bytes_seen = state.bytes_seen + byte_size(chunk)

    if bytes_seen > state.max_total_bytes do
      state
      |> Map.put(:bytes_seen, bytes_seen)
      |> Map.put(:input_truncated, true)
      |> incomplete("response_bytes_exceeded")
    else
      %{state | bytes_seen: bytes_seen}
    end
  end

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    bytes_seen = state.bytes_seen + byte_size(chunk)

    if bytes_seen > state.max_total_bytes do
      state
      |> Map.put(:bytes_seen, bytes_seen)
      |> Map.put(:input_truncated, true)
      |> incomplete("response_bytes_exceeded")
    else
      observe_slices(%{state | bytes_seen: bytes_seen}, chunk)
    end
  end

  def feed(%__MODULE__{} = state, _chunk), do: incomplete(state, "invalid_chunk")

  @spec finish(t(), atom()) :: t()
  def finish(%__MODULE__{transport_terminal: terminal} = state, _reason)
      when not is_nil(terminal),
      do: state

  def finish(%__MODULE__{} = state, reason) do
    state = if state.input_truncated, do: state, else: observe_finish(state)

    case reason do
      :eof -> finish_at_eof(state)
      :cancelled -> state |> Map.put(:transport_terminal, :cancelled) |> put_terminal(:cancelled)
      _ -> state |> Map.put(:transport_terminal, :failed) |> put_terminal(:incomplete)
    end
  end

  @spec observe_response(non_neg_integer(), binary(), keyword()) :: map()
  def observe_response(status, body, opts \\ []) when is_integer(status) and is_binary(body) do
    state = new(opts)

    state =
      cond do
        byte_size(body) > state.max_total_bytes ->
          state
          |> Map.put(:bytes_seen, byte_size(body))
          |> Map.put(:input_truncated, true)
          |> incomplete("response_bytes_exceeded")
          |> put_terminal(:incomplete)

        not String.valid?(body) ->
          state
          |> Map.put(:bytes_seen, byte_size(body))
          |> incomplete("invalid_utf8")
          |> put_terminal(:incomplete)

        true ->
          state
          |> Map.put(:bytes_seen, byte_size(body))
          |> measure_parse(fn state ->
            case Serialization.from_json(body, max_encoded_bytes: state.max_total_bytes) do
              {:ok, document} when is_map(document) -> observe_document(state, document)
              _ -> incomplete(state, "invalid_json")
            end
          end)
          |> finish_document(status)
      end

    facts(state)
  rescue
    _ -> facts(new(opts) |> incomplete("observer_exception") |> put_terminal(:incomplete))
  end

  @spec facts(t()) :: map()
  def facts(%__MODULE__{} = state) do
    finish_reasons =
      state.finish_reasons
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {index, reason} -> %{index: index, reason: reason} end)

    candidate_count = MapSet.size(state.candidates_seen)

    %{
      implementation: __MODULE__,
      source: source(state.operation),
      observation_status: state.observation_status,
      protocol_terminal: state.protocol_terminal,
      transport_terminal: state.transport_terminal,
      content_seen: state.content_seen,
      content_finished: state.content_finished,
      usage_status: state.usage_status,
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      cached_tokens: state.cached_tokens,
      reasoning_tokens: state.reasoning_tokens,
      native_total: state.native_total,
      native_usage: state.native_usage,
      count_tokens_total: state.count_tokens_total,
      finish_reason: primary_finish_reason(finish_reasons),
      finish_reasons: finish_reasons,
      candidate_count: candidate_count,
      candidate_ambiguous: candidate_count > 1,
      provider_request_id: state.provider_request_id,
      blocked: state.blocked,
      block_reason: state.block_reason,
      partial: state.partial or state.protocol_terminal in [:incomplete, :cancelled],
      error_code: state.error_code,
      error_type: state.error_type,
      bytes_seen: state.bytes_seen,
      events_seen: state.events_seen,
      parse_time_us: state.parse_time_us,
      parse_budget_exhausted: state.parse_budget_exhausted,
      input_truncated: state.input_truncated,
      diagnostics: Enum.reverse(state.diagnostics),
      diagnostics_truncated: state.diagnostics_truncated
    }
  end

  defp observe_slices(%{framer: %{closed?: true}} = state, _chunk), do: state

  defp observe_slices(state, chunk) when byte_size(chunk) > @feed_slice_bytes do
    <<slice::binary-size(@feed_slice_bytes), rest::binary>> = chunk
    state |> observe_chunk(slice) |> observe_slices(rest)
  end

  defp observe_slices(state, chunk), do: observe_chunk(state, chunk)

  defp observe_chunk(state, chunk) do
    case SSE.feed(state.framer, chunk) do
      {:ok, framer, events} ->
        reduce_events(%{state | framer: framer}, events)

      {:error, %Error{} = error, framer} ->
        state
        |> Map.put(:framer, framer)
        |> incomplete("invalid_sse")
        |> incomplete(framer_diagnostic(error))
    end
  rescue
    _ -> incomplete(state, "observer_exception")
  end

  defp observe_finish(state) do
    case SSE.finish(state.framer) do
      {:ok, framer, events} ->
        reduce_events(%{state | framer: framer}, events)

      {:error, %Error{} = error, framer} ->
        state
        |> Map.put(:framer, framer)
        |> incomplete("invalid_sse_eof")
        |> incomplete(framer_diagnostic(error))
    end
  rescue
    _ -> incomplete(state, "observer_exception")
  end

  defp reduce_events(state, events) do
    Enum.reduce_while(events, state, fn event, state ->
      if state.parse_budget_exhausted do
        {:halt, state}
      else
        reduce_event(state, event)
      end
    end)
  end

  defp reduce_event(state, event) do
    if state.events_seen >= state.max_events do
      {:halt, incomplete(state, "parse_event_budget_exceeded")}
    else
      state = %{state | events_seen: state.events_seen + 1}
      state = measure_parse(state, &observe_sse(event, &1))

      if state.parse_budget_exhausted, do: {:halt, state}, else: {:cont, state}
    end
  end

  defp observe_sse(%{data: "[DONE]"}, state),
    do: incomplete(state, "unexpected_done_marker")

  defp observe_sse(%{data: data}, state) do
    case Serialization.from_json(data, max_encoded_bytes: state.framer.max_frame_bytes) do
      {:ok, document} when is_map(document) -> observe_document(state, document)
      _ -> incomplete(state, "invalid_event_json")
    end
  end

  defp observe_document(%{operation: :count_tokens} = state, document) do
    state
    |> put_count_tokens(document)
    |> put_error(document)
  end

  defp observe_document(state, document) do
    state
    |> put_provider_id(document)
    |> put_usage(document)
    |> put_candidates(document)
    |> put_prompt_feedback(document)
    |> put_error(document)
  rescue
    _ -> incomplete(state, "observer_exception")
  end

  defp finish_document(%{error_code: code} = state, status)
       when status not in 200..299 or not is_nil(code),
       do: put_terminal(state, :failed)

  defp finish_document(%{parse_budget_exhausted: true} = state, _status),
    do: put_terminal(state, :incomplete)

  defp finish_document(%{operation: :count_tokens, count_tokens_total: total} = state, status)
       when status in 200..299 and is_integer(total),
       do: put_terminal(state, :completed)

  defp finish_document(%{operation: :count_tokens} = state, _status),
    do: state |> incomplete("missing_total_tokens") |> put_terminal(:incomplete)

  defp finish_document(state, status) when status in 200..299 do
    cond do
      state.blocked ->
        put_terminal(state, :incomplete)

      successful_finish?(state) ->
        put_terminal(state, :completed)

      partial_finish?(state) ->
        state |> Map.put(:partial, true) |> put_terminal(:incomplete)

      unknown_finish?(state) ->
        state |> incomplete("unknown_finish_reason") |> put_terminal(:incomplete)

      true ->
        state |> incomplete("missing_verified_finish") |> put_terminal(:incomplete)
    end
  end

  defp finish_document(state, _status), do: put_terminal(state, :failed)

  defp finish_at_eof(%{protocol_terminal: :failed} = state),
    do: %{state | transport_terminal: :eof}

  defp finish_at_eof(%{operation: :count_tokens} = state) do
    state
    |> Map.put(:transport_terminal, :eof)
    |> incomplete("count_tokens_stream_unsupported")
    |> put_terminal(:incomplete)
  end

  defp finish_at_eof(state) do
    state = %{state | transport_terminal: :eof}

    cond do
      state.parse_budget_exhausted ->
        put_terminal(state, :incomplete)

      state.blocked ->
        put_terminal(state, :incomplete)

      successful_finish?(state) ->
        put_terminal(state, :completed)

      partial_finish?(state) ->
        state |> Map.put(:partial, true) |> put_terminal(:incomplete)

      unknown_finish?(state) ->
        state |> incomplete("unknown_finish_reason") |> put_terminal(:incomplete)

      true ->
        state |> incomplete("missing_verified_finish") |> put_terminal(:incomplete)
    end
  end

  defp put_provider_id(state, %{"responseId" => id}) when is_binary(id),
    do: %{state | provider_request_id: String.slice(id, 0, 256)}

  defp put_provider_id(state, _document), do: state

  defp put_usage(state, %{"usageMetadata" => usage}) when is_map(usage) do
    {state, native_usage} = sanitize_usage(state, usage)

    state = %{
      state
      | input_tokens: native_usage[:prompt_token_count],
        output_tokens: native_usage[:candidates_token_count],
        cached_tokens: native_usage[:cached_content_token_count],
        reasoning_tokens: native_usage[:thoughts_token_count],
        native_total: native_usage[:total_token_count],
        native_usage: native_usage
    }

    %{state | usage_status: usage_status(state)}
  end

  defp put_usage(state, %{"usageMetadata" => nil}), do: state
  defp put_usage(state, %{"usageMetadata" => _}), do: incomplete(state, "invalid_usage_metadata")
  defp put_usage(state, _document), do: state

  defp sanitize_usage(state, usage) do
    Enum.reduce(@usage_counters, {state, %{}}, fn {wire_key, fact_key}, {state, facts} ->
      case Map.fetch(usage, wire_key) do
        {:ok, value} when is_integer(value) and value >= 0 ->
          {state, Map.put(facts, fact_key, value)}

        {:ok, nil} ->
          {state, facts}

        {:ok, _} ->
          {incomplete(state, "invalid_#{wire_key}"), facts}

        :error ->
          {state, facts}
      end
    end)
    |> then(fn {state, facts} ->
      Enum.reduce(@usage_details, {state, facts}, fn {wire_key, fact_key}, {state, facts} ->
        case modality_details(usage[wire_key]) do
          {:ok, nil} -> {state, facts}
          {:ok, details} -> {state, Map.put(facts, fact_key, details)}
          :error -> {incomplete(state, "invalid_#{wire_key}"), facts}
        end
      end)
    end)
  end

  defp modality_details(nil), do: {:ok, nil}

  defp modality_details(details) when is_list(details) and length(details) <= 32 do
    Enum.reduce_while(details, {:ok, []}, fn
      %{"modality" => modality, "tokenCount" => count}, {:ok, acc}
      when is_binary(modality) and is_integer(count) and count >= 0 ->
        {:cont, {:ok, [%{modality: String.slice(modality, 0, 64), token_count: count} | acc]}}

      _, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp modality_details(_), do: :error

  defp put_candidates(state, %{"candidates" => candidates}) when is_list(candidates) do
    state =
      candidates
      |> Enum.take(64)
      |> Enum.with_index()
      |> Enum.reduce(state, fn {candidate, fallback_index}, state ->
        put_candidate(state, candidate, fallback_index)
      end)

    state =
      if length(candidates) > 64,
        do: incomplete(state, "candidate_budget_exceeded"),
        else: state

    if MapSet.size(state.candidates_seen) > 1,
      do: incomplete(state, "multiple_candidates"),
      else: state
  end

  defp put_candidates(state, %{"candidates" => nil}), do: state
  defp put_candidates(state, %{"candidates" => _}), do: incomplete(state, "invalid_candidates")
  defp put_candidates(state, _document), do: state

  defp put_candidate(state, candidate, fallback_index) when is_map(candidate) do
    index = candidate_index(candidate, fallback_index)

    state = %{
      state
      | candidates_seen: MapSet.put(state.candidates_seen, index),
        content_seen: state.content_seen or candidate_content?(candidate)
    }

    case candidate["finishReason"] do
      reason when is_binary(reason) ->
        %{
          state
          | finish_reasons: Map.put(state.finish_reasons, index, String.slice(reason, 0, 128)),
            content_finished: true
        }

      nil ->
        state

      _ ->
        incomplete(state, "invalid_finish_reason")
    end
  end

  defp put_candidate(state, _candidate, _fallback_index),
    do: incomplete(state, "invalid_candidate")

  defp candidate_index(%{"index" => index}, _fallback) when is_integer(index) and index >= 0,
    do: index

  defp candidate_index(_candidate, fallback), do: fallback

  defp candidate_content?(%{"content" => %{"parts" => parts}}) when is_list(parts),
    do: parts != []

  defp candidate_content?(_candidate), do: false

  defp put_prompt_feedback(state, %{"promptFeedback" => feedback}) when is_map(feedback) do
    case feedback["blockReason"] do
      reason when is_binary(reason) ->
        %{
          state
          | blocked: true,
            block_reason: String.slice(reason, 0, 128),
            partial: true,
            content_finished: true
        }

      nil ->
        state

      _ ->
        incomplete(state, "invalid_block_reason")
    end
  end

  defp put_prompt_feedback(state, %{"promptFeedback" => nil}), do: state

  defp put_prompt_feedback(state, %{"promptFeedback" => _}),
    do: incomplete(state, "invalid_prompt_feedback")

  defp put_prompt_feedback(state, _document), do: state

  defp put_error(state, %{"error" => error}) when is_map(error) do
    %{
      state
      | error_code: safe_code(error["code"]),
        error_type: safe_code(error["status"] || error["type"]),
        partial: true,
        protocol_terminal: :failed
    }
  end

  defp put_error(state, %{"error" => nil}), do: state
  defp put_error(state, %{"error" => _}), do: incomplete(state, "invalid_error")
  defp put_error(state, _document), do: state

  defp put_count_tokens(state, document) do
    case document["totalTokens"] do
      total when is_integer(total) and total >= 0 ->
        %{state | count_tokens_total: total, usage_status: :not_applicable}

      nil ->
        state

      _ ->
        incomplete(state, "invalid_total_tokens")
    end
  end

  defp successful_finish?(state) do
    reasons = Map.values(state.finish_reasons)
    reasons != [] and Enum.all?(reasons, &(&1 in @success_finish_reasons))
  end

  defp partial_finish?(state) do
    reasons = Map.values(state.finish_reasons)

    reasons != [] and
      Enum.all?(reasons, &(&1 in (@success_finish_reasons ++ @partial_finish_reasons)))
  end

  defp unknown_finish?(state) do
    Enum.any?(Map.values(state.finish_reasons), fn reason ->
      reason not in @success_finish_reasons and reason not in @partial_finish_reasons
    end)
  end

  defp put_terminal(%{protocol_terminal: :failed} = state, _terminal), do: state
  defp put_terminal(state, terminal), do: %{state | protocol_terminal: terminal}

  defp usage_status(state) do
    cond do
      state.operation == :count_tokens ->
        :not_applicable

      is_integer(state.input_tokens) and is_integer(state.output_tokens) ->
        :complete

      Enum.any?(
        [
          state.input_tokens,
          state.output_tokens,
          state.cached_tokens,
          state.reasoning_tokens,
          state.native_total
        ],
        &is_integer/1
      ) ->
        :partial

      true ->
        :unknown
    end
  end

  defp incomplete(state, diagnostic) do
    state
    |> Map.put(:observation_status, :incomplete)
    |> Map.put(:partial, true)
    |> retain_diagnostic(diagnostic)
  end

  defp measure_parse(state, fun) do
    started_at = System.monotonic_time(:microsecond)
    next = fun.(state)
    elapsed = max(System.monotonic_time(:microsecond) - started_at, 0)
    parse_time_us = state.parse_time_us + elapsed
    next = %{next | parse_time_us: parse_time_us}

    if parse_time_us > state.max_parse_time_us do
      next
      |> Map.put(:parse_budget_exhausted, true)
      |> incomplete("parse_time_budget_exceeded")
    else
      next
    end
  end

  defp retain_diagnostic(%{diagnostics_truncated: true} = state, _diagnostic), do: state

  defp retain_diagnostic(state, diagnostic) do
    cond do
      diagnostic in state.diagnostics ->
        state

      length(state.diagnostics) < state.max_diagnostics ->
        %{state | diagnostics: [diagnostic | state.diagnostics]}

      true ->
        retained = state.diagnostics |> Enum.reverse() |> Enum.take(state.max_diagnostics - 1)

        %{
          state
          | diagnostics: Enum.reverse(retained ++ [@diagnostics_truncated]),
            diagnostics_truncated: true
        }
    end
  end

  defp framer_diagnostic(%Error{message: "SSE frame exceeds " <> _}),
    do: "sse_frame_bytes_exceeded"

  defp framer_diagnostic(%Error{message: "SSE buffer exceeds " <> _}),
    do: "sse_buffer_bytes_exceeded"

  defp framer_diagnostic(_error), do: "sse_framer_error"

  defp primary_finish_reason([%{reason: reason}]), do: reason
  defp primary_finish_reason([%{reason: reason} | _]), do: reason
  defp primary_finish_reason([]), do: nil

  defp safe_code(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_code(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp safe_code(_value), do: nil

  defp source(:count_tokens), do: :google_count_tokens
  defp source(_operation), do: :google_generate_content

  defp normalize_operation(operation) when operation in [:count_tokens, "count_tokens"],
    do: :count_tokens

  defp normalize_operation(_operation), do: :generate

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default
end
