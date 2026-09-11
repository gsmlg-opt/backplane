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
          protocol: :legacy | :compact | :responses,
          tool_calls: [map()],
          partial: boolean(),
          usage_complete: boolean(),
          metadata: map(),
          stream_chunks: non_neg_integer(),
          ttft_ms: non_neg_integer() | nil,
          stream_duration_ms: non_neg_integer() | nil
        }

  @spec new(:legacy | :compact | :responses | :openai_responses) :: pid()
  def new(protocol \\ :legacy)

  def new(:responses), do: new(:openai_responses)

  def new(:openai_responses) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          protocol: :openai_responses,
          observer: Backplane.AiProtocol.OpenAIResponsesObserver.new(),
          chunk_count: 0,
          first_chunk_at: nil,
          last_chunk_at: nil,
          started_at: System.monotonic_time(:millisecond)
        }
      end)

    pid
  end

  def new(:legacy) do
    new_legacy(:legacy)
  end

  def new(:compact) do
    new_legacy(:compact)
  end

  defp new_legacy(protocol) do
    {:ok, pid} =
      Agent.start_link(fn ->
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
      end)

    pid
  end

  @spec scan_chunk(pid(), binary()) :: :ok
  def scan_chunk(pid, chunk) when is_binary(chunk) do
    now = System.monotonic_time(:millisecond)

    Agent.update(pid, fn state ->
      state =
        state
        |> Map.update!(:chunk_count, &(&1 + 1))
        |> put_first_chunk(now)
        |> Map.put(:last_chunk_at, now)

      case state do
        %{protocol: :openai_responses, observer: observer} ->
          %{state | observer: Backplane.AiProtocol.OpenAIResponsesObserver.feed(observer, chunk)}

        _ ->
          state
      end
    end)

    state = Agent.get(pid, & &1)

    if state[:protocol] != :openai_responses and
         (String.contains?(chunk, "\"usage\"") or String.contains?(chunk, "\"finish_reason\"") or
            String.contains?(chunk, "\"stop_reason\"") or String.contains?(chunk, "\"id\"")) do
      extract_usage_from_chunk(pid, chunk)
    end

    :ok
  end

  @spec get_tokens(pid()) :: {integer() | nil, integer() | nil}
  def get_tokens(pid) do
    snapshot = snapshot(pid)
    stop(pid)
    {snapshot.input_tokens, snapshot.output_tokens}
  end

  @spec snapshot(pid()) :: snapshot()
  def snapshot(pid) do
    state =
      Agent.get_and_update(pid, fn
        %{protocol: :openai_responses, observer: observer} = state ->
          observer = Backplane.AiProtocol.OpenAIResponsesObserver.finish(observer, :eof)
          next = %{state | observer: observer}
          {next, next}

        state ->
          {state, state}
      end)

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

    case state do
      %{protocol: :openai_responses, observer: observer} ->
        facts = Backplane.AiProtocol.OpenAIResponsesObserver.facts(observer)

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
          usage_complete:
            facts.observation_status == :complete and facts.usage_status == :complete,
          metadata: %{protocol_observation: sanitize_facts(facts)}
        })

      _ ->
        base
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp put_first_chunk(state, now) do
    if state.first_chunk_at, do: state, else: Map.put(state, :first_chunk_at, now)
  end

  defp extract_usage_from_chunk(pid, chunk) do
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.each(fn line ->
      json_str = String.trim_leading(line, "data: ")

      case Jason.decode(json_str) do
        {:ok, data} -> extract_from_parsed(pid, data)
        _ -> :ok
      end
    end)
  end

  defp extract_from_parsed(pid, %{"message" => %{"usage" => usage}} = data) do
    update_tokens(pid, usage)
    update_provider_request_id(pid, get_in(data, ["message", "id"]))
  end

  defp extract_from_parsed(pid, %{"usage" => usage} = data) when is_map(usage) do
    update_tokens(pid, usage)
    update_provider_request_id(pid, Map.get(data, "id"))
  end

  defp extract_from_parsed(pid, %{"choices" => [%{"finish_reason" => reason} | _]} = data)
       when is_binary(reason) do
    Agent.update(pid, fn state -> Map.put(state, :finish_reason, reason) end)
    update_provider_request_id(pid, Map.get(data, "id"))
  end

  defp extract_from_parsed(pid, %{"delta" => %{"stop_reason" => reason}})
       when is_binary(reason) do
    Agent.update(pid, fn state -> Map.put(state, :finish_reason, reason) end)
  end

  defp extract_from_parsed(_, _), do: :ok

  defp update_tokens(pid, usage) when is_map(usage) do
    Agent.update(pid, fn state ->
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
    end)
  end

  defp update_provider_request_id(pid, id) when is_binary(id) do
    Agent.update(pid, fn state -> Map.put(state, :provider_request_id, id) end)
  end

  defp update_provider_request_id(_pid, _), do: :ok

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

  defp normalize_tool_call(%{arguments: arguments} = tool) when is_binary(arguments) do
    decoded =
      case Jason.decode(arguments) do
        {:ok, value} when is_map(value) -> value
        _ -> arguments
      end

    %{tool | arguments: decoded}
  end

  defp partial_observation?(facts) do
    facts.observation_status != :complete or
      Enum.any?(facts.tool_calls, &(&1.complete != true))
  end

  defp complete_counters?(input, output) do
    is_integer(input) and input >= 0 and is_integer(output) and output >= 0
  end

  defp legacy_protocol(:compact), do: :compact
  defp legacy_protocol(_protocol), do: :legacy
end
