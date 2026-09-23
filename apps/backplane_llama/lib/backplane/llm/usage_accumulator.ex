defmodule Backplane.LLM.UsageAccumulator do
  @moduledoc "Accumulates token usage and streaming metrics from SSE chunks."

  @type snapshot :: %{
          input_tokens: integer() | nil,
          output_tokens: integer() | nil,
          cached_tokens: integer() | nil,
          reasoning_tokens: integer() | nil,
          finish_reason: String.t() | nil,
          provider_request_id: String.t() | nil,
          observation_status: atom() | nil,
          protocol_terminal: atom() | nil,
          error_code: String.t() | nil,
          error_type: String.t() | nil,
          protocol: :legacy | :compact | :responses | :google_generate_content,
          tool_calls: [map()],
          partial: boolean(),
          usage_complete: boolean(),
          metadata: map(),
          stream_chunks: non_neg_integer() | nil,
          ttft_ms: non_neg_integer() | nil,
          stream_duration_ms: non_neg_integer() | nil
        }

  @max_response_body_bytes 8_388_608
  @max_observation_chunk_bytes 1_048_576
  @default_max_queue 256
  @default_snapshot_timeout 50
  @meta_key {__MODULE__, :meta}

  @spec new(
          :legacy
          | :compact
          | :responses
          | :openai_responses
          | :openai_responses_body
          | :openai_json_body
          | :anthropic_json_body
          | :google_generate_content
          | :google_antigravity
          | :google_antigravity_body
          | :google_generate_content_body
          | :google_count_tokens_body
        ) :: pid()
  def new(protocol \\ :legacy)

  def new(protocol), do: new(protocol, [])

  @spec new(
          :legacy
          | :compact
          | :responses
          | :openai_responses
          | :openai_responses_body
          | :openai_json_body
          | :anthropic_json_body
          | :google_generate_content
          | :google_antigravity
          | :google_antigravity_body
          | :google_generate_content_body
          | :google_count_tokens_body,
          keyword()
        ) :: pid()
  def new(protocol, opts) do
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)
    snapshot_timeout = Keyword.get(opts, :snapshot_timeout, @default_snapshot_timeout)

    state =
      case protocol do
        :responses -> responses_state()
        :openai_responses -> responses_state()
        :openai_responses_body -> response_body_state()
        :openai_json_body -> json_body_state(:openai_json_body)
        :anthropic_json_body -> json_body_state(:anthropic_json_body)
        :google_generate_content -> google_generate_content_state()
        :google_antigravity -> antigravity_state()
        :google_antigravity_body -> response_body_state(:google_antigravity_body)
        :google_generate_content_body -> response_body_state(:google_generate_content_body)
        :google_count_tokens_body -> response_body_state(:google_count_tokens_body)
        :legacy -> legacy_state(:legacy)
        :compact -> legacy_state(:compact)
      end

    start_owner(state, max_queue, snapshot_timeout)
  end

  defp responses_state do
    %{
      protocol: :openai_responses,
      observer: Backplane.AiProtocol.OpenAIResponsesObserver.new(),
      chunk_count: 0,
      first_chunk_at: nil,
      last_chunk_at: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp response_body_state do
    response_body_state(:openai_responses_body)
  end

  defp response_body_state(protocol) do
    %{
      protocol: protocol,
      body_chunks: [],
      body_bytes: 0,
      body_truncated: false,
      chunk_count: 0,
      first_chunk_at: nil,
      first_content_at: nil,
      last_chunk_at: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp json_body_state(protocol) do
    response_body_state(protocol)
  end

  defp google_generate_content_state do
    %{
      protocol: :google_generate_content,
      observer: Backplane.AiProtocol.GoogleGenerateContentObserver.new(),
      chunk_count: 0,
      first_chunk_at: nil,
      first_content_at: nil,
      last_chunk_at: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp antigravity_state do
    %{
      protocol: :google_antigravity,
      observer: Backplane.AiProtocol.Antigravity.Observer.new(),
      chunk_count: 0,
      first_chunk_at: nil,
      first_content_at: nil,
      last_chunk_at: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp legacy_state(protocol) do
    %{
      protocol: protocol,
      input_tokens: nil,
      output_tokens: nil,
      cached_tokens: nil,
      reasoning_tokens: nil,
      finish_reason: nil,
      provider_request_id: nil,
      chunk_count: 0,
      first_chunk_at: nil,
      last_chunk_at: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp start_owner(state, max_queue, snapshot_timeout) do
    atomics = :atomics.new(5, [])

    {:ok, pid} =
      Agent.start(fn ->
        Process.put(@meta_key, {atomics, max_queue, snapshot_timeout})
        state
      end)

    pid
  end

  @spec scan_chunk(pid(), binary()) :: :ok
  def scan_chunk(pid, chunk) when is_binary(chunk) do
    case accumulator_meta(pid) do
      {:ok, atomics, max_queue, _timeout} ->
        if byte_size(chunk) > @max_observation_chunk_bytes do
          :atomics.add(atomics, 1, 1)
          :atomics.add(atomics, 4, 1)
          :atomics.add(atomics, 5, byte_size(chunk))
        else
          enqueue_chunk(pid, chunk, atomics, max_queue)
        end

      _ ->
        :ok
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp enqueue_chunk(pid, chunk, atomics, max_queue) do
    pending = :atomics.add_get(atomics, 3, 1)

    if not Process.alive?(pid) or pending > max_queue do
      :atomics.add(atomics, 1, 1)
      :atomics.put(atomics, 2, 1)
      :atomics.add(atomics, 5, byte_size(chunk))
      :atomics.sub(atomics, 3, 1)
    else
      Agent.cast(pid, fn state ->
        try do
          scan_state(state, chunk)
        after
          :atomics.sub(atomics, 3, 1)
        end
      end)
    end
  end

  @spec get_tokens(pid()) :: {integer() | nil, integer() | nil}
  def get_tokens(pid) do
    snapshot = snapshot(pid)
    stop(pid)
    {snapshot.input_tokens, snapshot.output_tokens}
  end

  @spec snapshot(pid(), non_neg_integer(), atom()) :: snapshot()
  def snapshot(pid, status \\ 200, transport_reason \\ :eof) do
    state =
      try do
        Agent.get_and_update(
          pid,
          fn
            %{protocol: :openai_responses, observer: observer} = state ->
              observer =
                Backplane.AiProtocol.OpenAIResponsesObserver.finish(observer, transport_reason)

              next = %{state | observer: observer}
              {next, next}

            %{protocol: :google_generate_content, observer: observer} = state ->
              observer =
                Backplane.AiProtocol.GoogleGenerateContentObserver.finish(
                  observer,
                  transport_reason
                )

              next =
                state
                |> Map.put(:observer, observer)
                |> put_google_first_content(System.monotonic_time(:millisecond))

              {next, next}

            %{protocol: :google_antigravity, observer: observer} = state ->
              observer =
                Backplane.AiProtocol.Antigravity.Observer.finish(observer, transport_reason)

              next =
                state
                |> Map.put(:observer, observer)
                |> put_antigravity_first_content(System.monotonic_time(:millisecond))

              {next, next}

            %{body_facts: _facts} = state ->
              {state, state}

            %{protocol: protocol} = state
            when protocol in [
                   :google_generate_content_body,
                   :google_count_tokens_body,
                   :google_antigravity_body
                 ] ->
              facts = google_response_body_facts(state, status)

              facts = apply_google_body_transport(facts, transport_reason)

              next =
                state
                |> Map.put(:body_facts, facts)
                |> put_google_body_first_content(facts, System.monotonic_time(:millisecond))

              {next, next}

            state ->
              {state, state}
          end,
          snapshot_timeout(pid)
        )
      catch
        :exit, _ -> :unavailable
      end

    if state == :unavailable,
      do: unavailable_snapshot(pid),
      else: snapshot_from_state(state, status, pid)
  end

  defp snapshot_from_state(state, status, pid) do
    first = state.first_chunk_at
    last = state.last_chunk_at
    started = state.started_at

    base = %{
      input_tokens: state[:input_tokens],
      output_tokens: state[:output_tokens],
      cached_tokens: state[:cached_tokens],
      reasoning_tokens: state[:reasoning_tokens],
      finish_reason: state[:finish_reason],
      provider_request_id: state[:provider_request_id],
      stream_chunks: state.chunk_count,
      ttft_ms: if(first, do: first - started, else: nil),
      stream_duration_ms: if(first && last, do: last - first, else: nil),
      observation_status: nil,
      protocol_terminal: nil,
      error_code: nil,
      error_type: nil,
      protocol: legacy_protocol(state.protocol),
      tool_calls: [],
      partial: false,
      usage_complete: complete_counters?(state[:input_tokens], state[:output_tokens]),
      metadata: %{}
    }

    snapshot =
      case state do
        %{protocol: :openai_responses, observer: observer} ->
          facts = Backplane.AiProtocol.OpenAIResponsesObserver.facts(observer)

          merge_observer_facts(base, facts)

        %{protocol: :openai_responses_body} = state ->
          facts = response_body_facts(state, status)

          merge_observer_facts(base, facts)

        %{protocol: :google_generate_content, observer: observer} ->
          facts = Backplane.AiProtocol.GoogleGenerateContentObserver.facts(observer)

          merge_google_observer_facts(base, facts, first_content_ms(state))

        %{protocol: :google_antigravity, observer: observer} ->
          facts = Backplane.AiProtocol.Antigravity.Observer.facts(observer)

          merge_google_observer_facts(base, facts, first_content_ms(state))

        %{protocol: protocol} = state
        when protocol in [
               :google_generate_content_body,
               :google_count_tokens_body,
               :google_antigravity_body
             ] ->
          facts = state.body_facts

          merge_google_observer_facts(base, facts, first_content_ms(state))

        %{protocol: protocol} = state
        when protocol in [:openai_json_body, :anthropic_json_body] ->
          merge_json_body_usage(base, state)

        _ ->
          base
      end

    snapshot
    |> mark_parser_failure(state)
    |> apply_observation_limits(pid)
  end

  defp merge_json_body_usage(base, state) do
    body = state.body_chunks |> Enum.reverse() |> IO.iodata_to_binary()

    decoded =
      case Jason.decode(body) do
        {:ok, data} when is_map(data) -> data
        _ -> %{}
      end

    usage = if is_map(decoded["usage"]), do: decoded["usage"], else: %{}

    input = usage["input_tokens"] || usage["prompt_tokens"]
    output = usage["output_tokens"] || usage["completion_tokens"]

    %{
      base
      | input_tokens: input,
        output_tokens: output,
        cached_tokens:
          get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
            usage["cache_read_input_tokens"],
        reasoning_tokens:
          get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
            usage["reasoning_tokens"],
        finish_reason: json_finish_reason(decoded),
        provider_request_id: decoded["id"],
        observation_status: if(state.body_truncated, do: :incomplete, else: :complete),
        partial: state.body_truncated,
        usage_complete: not state.body_truncated and complete_counters?(input, output),
        metadata:
          if(state.body_truncated,
            do: %{observation: %{body_truncated: true, bytes_seen: state.body_bytes}},
            else: %{}
          )
    }
  end

  defp json_finish_reason(%{"choices" => [%{"finish_reason" => reason} | _]}), do: reason
  defp json_finish_reason(%{"stop_reason" => reason}), do: reason
  defp json_finish_reason(_), do: nil

  defp mark_parser_failure(snapshot, %{observer_error: true}) do
    %{
      snapshot
      | observation_status: :incomplete,
        protocol_terminal: :incomplete,
        partial: true,
        usage_complete: false,
        metadata: Map.put(snapshot.metadata, :observation, %{parser_failed: true})
    }
  end

  defp mark_parser_failure(snapshot, _state), do: snapshot

  defp merge_observer_facts(base, facts) do
    Map.merge(base, %{
      input_tokens: facts.input_tokens,
      output_tokens: facts.output_tokens,
      cached_tokens: facts.cached_tokens,
      reasoning_tokens: facts.reasoning_tokens,
      finish_reason: facts.finish_reason || terminal_reason(facts.protocol_terminal),
      provider_request_id: facts.provider_request_id,
      observation_status: facts.observation_status,
      protocol_terminal: facts.protocol_terminal,
      error_code: facts.error_code,
      error_type: facts.error_type,
      protocol: :responses,
      tool_calls: Enum.map(facts.tool_calls, &normalize_tool_call/1),
      partial: partial_observation?(facts),
      usage_complete: facts.observation_status == :complete and facts.usage_status == :complete,
      metadata: %{protocol_observation: sanitize_facts(facts)}
    })
  end

  defp merge_google_observer_facts(base, facts, first_content_ms) do
    Map.merge(base, %{
      input_tokens: facts.input_tokens,
      output_tokens: facts.output_tokens,
      cached_tokens: facts.cached_tokens,
      reasoning_tokens: facts.reasoning_tokens,
      finish_reason: facts.finish_reason,
      provider_request_id: facts.provider_request_id,
      observation_status: facts.observation_status,
      protocol_terminal: facts.protocol_terminal,
      error_code: facts.error_code,
      error_type: facts.error_type,
      protocol: :google_generate_content,
      tool_calls: [],
      partial: facts.partial,
      usage_complete:
        facts.source == :google_generate_content and facts.usage_status == :complete and
          facts.observation_status == :complete,
      metadata: google_metadata(facts, first_content_ms)
    })
  end

  defp google_metadata(%{source: :google_count_tokens} = facts, first_content_ms) do
    %{
      protocol_observation: sanitize_google_facts(facts),
      operation: %{name: "count_tokens", total_tokens: facts.count_tokens_total},
      timing: %{first_content_ms: first_content_ms}
    }
  end

  defp google_metadata(facts, first_content_ms) do
    %{
      protocol_observation: sanitize_google_facts(facts),
      timing: %{first_content_ms: first_content_ms},
      usage_semantics: %{
        input_tokens: "promptTokenCount_includes_cached_content",
        output_tokens: "candidatesTokenCount_excludes_thoughts",
        cached_tokens: "cachedContentTokenCount_subset_of_input",
        reasoning_tokens: "thoughtsTokenCount",
        native_total: "totalTokenCount_unmodified"
      }
    }
  end

  defp response_body_facts(state, status) do
    body = state.body_chunks |> Enum.reverse() |> IO.iodata_to_binary()

    facts = Backplane.AiProtocol.OpenAIResponsesObserver.observe_response(status, body)

    if state.body_truncated do
      facts
      |> Map.merge(%{
        observation_status: :incomplete,
        protocol_terminal: :incomplete,
        usage_status: :unknown,
        input_tokens: nil,
        output_tokens: nil,
        cached_tokens: nil,
        reasoning_tokens: nil,
        finish_reason: nil,
        provider_request_id: nil,
        tool_calls: [],
        input_truncated: true,
        bytes_seen: state.body_bytes
      })
      |> Map.update!(:diagnostics, &Enum.take(["response_bytes_exceeded" | &1], 32))
    else
      facts
    end
  end

  defp google_response_body_facts(state, status) do
    body = state.body_chunks |> Enum.reverse() |> IO.iodata_to_binary()

    operation =
      if state.protocol == :google_count_tokens_body,
        do: :count_tokens,
        else: :generate

    facts =
      if state.protocol == :google_antigravity_body do
        Backplane.AiProtocol.Antigravity.Observer.observe_response(status, body)
      else
        Backplane.AiProtocol.GoogleGenerateContentObserver.observe_response(status, body,
          operation: operation
        )
      end

    if state.body_truncated do
      facts
      |> Map.merge(%{
        observation_status: :incomplete,
        protocol_terminal: :incomplete,
        usage_status: :unknown,
        input_tokens: nil,
        output_tokens: nil,
        cached_tokens: nil,
        reasoning_tokens: nil,
        native_total: nil,
        native_usage: %{},
        count_tokens_total: nil,
        finish_reason: nil,
        finish_reasons: [],
        provider_request_id: nil,
        input_truncated: true,
        partial: true,
        bytes_seen: state.body_bytes
      })
      |> Map.update!(:diagnostics, &Enum.take(["response_bytes_exceeded" | &1], 32))
    else
      facts
    end
  end

  defp apply_google_body_transport(facts, :eof), do: Map.put(facts, :transport_terminal, :eof)

  defp apply_google_body_transport(facts, :cancelled) do
    Map.merge(facts, %{
      observation_status: :incomplete,
      protocol_terminal: :cancelled,
      transport_terminal: :cancelled,
      partial: true,
      usage_status: :unknown
    })
  end

  defp apply_google_body_transport(facts, _reason) do
    Map.merge(facts, %{
      observation_status: :incomplete,
      protocol_terminal: :incomplete,
      transport_terminal: :failed,
      partial: true,
      usage_status: :unknown
    })
  end

  defp put_response_body_chunk(%{body_truncated: true} = state, chunk) do
    Map.update!(state, :body_bytes, &(&1 + byte_size(chunk)))
  end

  defp put_response_body_chunk(state, chunk) do
    bytes = state.body_bytes + byte_size(chunk)

    if bytes > @max_response_body_bytes do
      %{state | body_bytes: bytes, body_truncated: true}
    else
      %{state | body_chunks: [chunk | state.body_chunks], body_bytes: bytes}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp put_first_chunk(state, now) do
    if state.first_chunk_at, do: state, else: Map.put(state, :first_chunk_at, now)
  end

  defp scan_state(state, chunk) do
    now = System.monotonic_time(:millisecond)

    state =
      state
      |> Map.update!(:chunk_count, &(&1 + 1))
      |> put_first_chunk(now)
      |> Map.put(:last_chunk_at, now)

    try do
      next =
        case state do
          %{protocol: :openai_responses, observer: observer} ->
            %{
              state
              | observer: Backplane.AiProtocol.OpenAIResponsesObserver.feed(observer, chunk)
            }

          %{protocol: :google_generate_content, observer: observer} ->
            %{
              state
              | observer: Backplane.AiProtocol.GoogleGenerateContentObserver.feed(observer, chunk)
            }

          %{protocol: :google_antigravity, observer: observer} ->
            %{
              state
              | observer: Backplane.AiProtocol.Antigravity.Observer.feed(observer, chunk)
            }

          %{protocol: :openai_responses_body} ->
            put_response_body_chunk(state, chunk)

          %{protocol: protocol}
          when protocol in [
                 :google_generate_content_body,
                 :google_count_tokens_body,
                 :google_antigravity_body
               ] ->
            put_response_body_chunk(state, chunk)

          %{protocol: protocol} when protocol in [:openai_json_body, :anthropic_json_body] ->
            put_response_body_chunk(state, chunk)

          _ ->
            extract_usage_from_chunk(state, chunk)
        end

      next |> put_google_first_content(now) |> put_antigravity_first_content(now)
    rescue
      _ -> Map.put(state, :observer_error, true)
    end
  end

  defp extract_usage_from_chunk(state, chunk) do
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.reduce(state, fn line, state ->
      json_str = String.trim_leading(line, "data: ")

      case Jason.decode(json_str) do
        {:ok, data} -> extract_from_parsed(state, data)
        _ -> state
      end
    end)
  end

  defp extract_from_parsed(state, %{"message" => %{"usage" => usage}} = data) do
    state |> update_tokens(usage) |> update_provider_request_id(get_in(data, ["message", "id"]))
  end

  defp extract_from_parsed(state, %{"usage" => usage} = data) when is_map(usage) do
    state |> update_tokens(usage) |> update_provider_request_id(Map.get(data, "id"))
  end

  defp extract_from_parsed(state, %{"choices" => [%{"finish_reason" => reason} | _]} = data)
       when is_binary(reason) do
    state |> Map.put(:finish_reason, reason) |> update_provider_request_id(Map.get(data, "id"))
  end

  defp extract_from_parsed(state, %{"delta" => %{"stop_reason" => reason}})
       when is_binary(reason) do
    Map.put(state, :finish_reason, reason)
  end

  defp extract_from_parsed(state, _), do: state

  defp update_tokens(state, usage) when is_map(usage) do
    input = usage["input_tokens"] || usage["prompt_tokens"] || state.input_tokens
    output = usage["output_tokens"] || usage["completion_tokens"] || state.output_tokens

    cached =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        usage["cache_read_input_tokens"] || state.cached_tokens

    reasoning =
      get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
        usage["reasoning_tokens"] || state.reasoning_tokens

    %{
      state
      | input_tokens: input,
        output_tokens: output,
        cached_tokens: cached,
        reasoning_tokens: reasoning
    }
  end

  defp update_provider_request_id(state, id) when is_binary(id) do
    Map.put(state, :provider_request_id, id)
  end

  defp update_provider_request_id(state, _), do: state

  defp accumulator_meta(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @meta_key, 0) do
          {@meta_key, {atomics, max_queue, timeout}} ->
            {:ok, atomics, max_queue, timeout}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp snapshot_timeout(pid) do
    case accumulator_meta(pid) do
      {:ok, _, _, timeout} -> timeout
      _ -> 0
    end
  end

  defp unavailable_snapshot(pid) do
    apply_observation_limits(
      %{
        input_tokens: nil,
        output_tokens: nil,
        cached_tokens: nil,
        reasoning_tokens: nil,
        finish_reason: nil,
        provider_request_id: nil,
        stream_chunks: nil,
        ttft_ms: nil,
        stream_duration_ms: nil,
        observation_status: :unavailable,
        protocol_terminal: :incomplete,
        error_code: nil,
        error_type: nil,
        protocol: :legacy,
        tool_calls: [],
        partial: true,
        usage_complete: false,
        metadata: %{}
      },
      pid
    )
  end

  defp apply_observation_limits(snapshot, pid) do
    case accumulator_meta(pid) do
      {:ok, atomics, _, _} ->
        dropped = :atomics.get(atomics, 1)

        if dropped > 0 do
          metadata =
            snapshot.metadata
            |> add_dropped_bytes(:atomics.get(atomics, 5))
            |> Map.put(:observation, %{
              dropped_chunks: dropped,
              dropped_bytes: :atomics.get(atomics, 5),
              queue_saturated: :atomics.get(atomics, 2) == 1,
              oversized_chunks: :atomics.get(atomics, 4)
            })

          %{
            snapshot
            | input_tokens: nil,
              output_tokens: nil,
              cached_tokens: nil,
              reasoning_tokens: nil,
              provider_request_id: nil,
              tool_calls: [],
              observation_status:
                if(snapshot.observation_status == :unavailable,
                  do: :unavailable,
                  else: :incomplete
                ),
              partial: true,
              usage_complete: false,
              metadata: metadata
          }
        else
          snapshot
        end

      _ ->
        snapshot
    end
  end

  defp add_dropped_bytes(%{protocol_observation: facts} = metadata, dropped_bytes)
       when is_map(facts) do
    diagnostics =
      ["observation_chunks_dropped" | List.wrap(facts[:diagnostics])]
      |> Enum.uniq()
      |> Enum.take(32)

    facts =
      facts
      |> Map.put(:observation_status, :incomplete)
      |> Map.put(:protocol_terminal, :incomplete)
      |> Map.put(:usage_status, :unknown)
      |> Map.put(:input_truncated, true)
      |> Map.put(:diagnostics, diagnostics)

    Map.put(
      metadata,
      :protocol_observation,
      Map.update(facts, :bytes_seen, dropped_bytes, fn
        bytes when is_integer(bytes) -> bytes + dropped_bytes
        _ -> dropped_bytes
      end)
    )
  end

  defp add_dropped_bytes(metadata, _dropped_bytes), do: metadata

  defp terminal_reason(:completed), do: "stop"
  defp terminal_reason(:incomplete), do: "incomplete"
  defp terminal_reason(:failed), do: "failed"
  defp terminal_reason(:cancelled), do: "cancelled"
  defp terminal_reason(:interrupted), do: "interrupted"
  defp terminal_reason(_), do: nil

  defp sanitize_facts(facts) do
    Map.take(facts, [
      :implementation,
      :observation_status,
      :protocol_terminal,
      :terminal_count,
      :usage_status,
      :bytes_seen,
      :events_seen,
      :diagnostics,
      :diagnostics_truncated,
      :input_truncated
    ])
    |> Map.update(:implementation, nil, &inspect/1)
  end

  defp sanitize_google_facts(facts) do
    Map.take(facts, [
      :implementation,
      :source,
      :observation_status,
      :protocol_terminal,
      :transport_terminal,
      :content_seen,
      :content_finished,
      :usage_status,
      :native_total,
      :native_usage,
      :finish_reasons,
      :candidate_count,
      :candidate_ambiguous,
      :blocked,
      :block_reason,
      :partial,
      :bytes_seen,
      :events_seen,
      :parse_time_us,
      :parse_budget_exhausted,
      :diagnostics,
      :diagnostics_truncated,
      :input_truncated
    ])
    |> Map.update(:implementation, nil, &inspect/1)
  end

  defp normalize_tool_call(%{arguments: arguments} = tool) when is_binary(arguments) do
    decoded =
      case Jason.decode(arguments) do
        {:ok, value} when is_map(value) -> value
        _ -> arguments
      end

    %{tool | arguments: decoded}
  end

  defp put_google_first_content(
         %{protocol: :google_generate_content, first_content_at: nil, observer: observer} = state,
         now
       ) do
    if observer.content_seen, do: %{state | first_content_at: now}, else: state
  end

  defp put_google_first_content(state, _now), do: state

  defp put_antigravity_first_content(
         %{protocol: :google_antigravity, first_content_at: nil, observer: observer} = state,
         now
       ) do
    if Backplane.AiProtocol.Antigravity.Observer.facts(observer).content_seen,
      do: %{state | first_content_at: now},
      else: state
  end

  defp put_antigravity_first_content(state, _now), do: state

  defp put_google_body_first_content(%{first_content_at: nil} = state, facts, now) do
    if facts.content_seen, do: %{state | first_content_at: now}, else: state
  end

  defp put_google_body_first_content(state, _facts, _now), do: state

  defp first_content_ms(%{first_content_at: first_content_at, started_at: started_at})
       when is_integer(first_content_at),
       do: max(first_content_at - started_at, 0)

  defp first_content_ms(_state), do: nil

  defp partial_observation?(facts) do
    facts.observation_status != :complete or
      Enum.any?(facts.tool_calls, &(&1.complete != true))
  end

  defp complete_counters?(input, output) do
    is_integer(input) and input >= 0 and is_integer(output) and output >= 0
  end

  defp legacy_protocol(:compact), do: :compact
  defp legacy_protocol(:google_generate_content), do: :google_generate_content
  defp legacy_protocol(:google_antigravity), do: :google_antigravity
  defp legacy_protocol(:google_antigravity_body), do: :google_antigravity
  defp legacy_protocol(:google_generate_content_body), do: :google_generate_content
  defp legacy_protocol(:google_count_tokens_body), do: :google_generate_content
  defp legacy_protocol(_protocol), do: :legacy
end
