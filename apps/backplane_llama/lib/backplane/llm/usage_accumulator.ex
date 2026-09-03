defmodule Backplane.LLM.UsageAccumulator do
  @moduledoc "Accumulates token usage and streaming metrics from SSE chunks."

  @type snapshot :: %{
          input_tokens: integer() | nil,
          output_tokens: integer() | nil,
          cached_tokens: integer() | nil,
          reasoning_tokens: integer() | nil,
          finish_reason: String.t() | nil,
          provider_request_id: String.t() | nil,
          stream_chunks: non_neg_integer(),
          ttft_ms: non_neg_integer() | nil,
          stream_duration_ms: non_neg_integer() | nil
        }

  @spec new() :: pid()
  def new do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
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
      state
      |> Map.update!(:chunk_count, &(&1 + 1))
      |> put_first_chunk(now)
      |> Map.put(:last_chunk_at, now)
    end)

    if String.contains?(chunk, "\"usage\"") or String.contains?(chunk, "\"finish_reason\"") or
         String.contains?(chunk, "\"stop_reason\"") or String.contains?(chunk, "\"id\"") do
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
    state = Agent.get(pid, & &1)
    first = state.first_chunk_at
    last = state.last_chunk_at
    started = state.started_at

    %{
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      cached_tokens: state.cached_tokens,
      reasoning_tokens: state.reasoning_tokens,
      finish_reason: state.finish_reason,
      provider_request_id: state.provider_request_id,
      stream_chunks: state.chunk_count,
      ttft_ms: if(first, do: first - started, else: nil),
      stream_duration_ms: if(first && last, do: last - first, else: nil)
    }
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

  defp extract_from_parsed(pid, %{"delta" => %{"stop_reason" => reason}}) when is_binary(reason) do
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
end
