defmodule Backplane.LLM.UsageAccumulator do
  @moduledoc "Accumulates token usage from SSE stream chunks via Agent."

  @spec new() :: pid()
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{input_tokens: nil, output_tokens: nil} end)
    pid
  end

  @spec scan_chunk(pid(), binary()) :: :ok
  def scan_chunk(pid, chunk) when is_binary(chunk) do
    if String.contains?(chunk, "\"usage\"") do
      extract_usage_from_chunk(pid, chunk)
    end

    :ok
  end

  @spec get_tokens(pid()) :: {integer() | nil, integer() | nil}
  def get_tokens(pid) do
    state = Agent.get(pid, & &1)
    Agent.stop(pid)
    {state.input_tokens, state.output_tokens}
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

  # Anthropic: message_start has {"message": {"usage": {"input_tokens": N}}}
  defp extract_from_parsed(pid, %{"message" => %{"usage" => usage}}) do
    update_tokens(pid, usage)
  end

  # Both Anthropic message_delta and OpenAI final chunk have {"usage": {...}}
  defp extract_from_parsed(pid, %{"usage" => usage}) when is_map(usage) do
    update_tokens(pid, usage)
  end

  defp extract_from_parsed(_, _), do: :ok

  defp update_tokens(pid, usage) when is_map(usage) do
    Agent.update(pid, fn state ->
      # Anthropic uses input_tokens/output_tokens, OpenAI uses prompt_tokens/completion_tokens
      input = usage["input_tokens"] || usage["prompt_tokens"] || state.input_tokens
      output = usage["output_tokens"] || usage["completion_tokens"] || state.output_tokens
      %{state | input_tokens: input, output_tokens: output}
    end)
  end
end
