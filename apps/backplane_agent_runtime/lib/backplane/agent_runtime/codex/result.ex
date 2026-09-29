defmodule Backplane.AgentRuntime.Codex.Result do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Provider-facing result shaping without discarding structured content.
  """

  @spec success(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def success(result, opts \\ [])

  def success(result, opts) when is_map(result) do
    with :ok <- bounded(result, Keyword.get(opts, :output_limit, 1_048_576)) do
      {:ok,
       %{
         type: :tool_result,
         content: Map.get(result, :content, Map.get(result, "content", result)),
         structured: Map.get(result, :structured, Map.get(result, "structured")),
         artifacts: List.wrap(Map.get(result, :artifacts, Map.get(result, "artifacts", []))),
         progress: Map.get(result, :progress, Map.get(result, "progress"))
       }}
    end
  end

  def success(_result, _opts),
    do: {:error, Error.new(:malformed_result, "tool result must be a map")}

  @spec failure(Error.t() | term()) :: map()
  def failure(%Error{} = error), do: %{type: :tool_error, error: Error.to_map(error)}

  def failure(reason),
    do: failure(Error.new(:execution_failure, "tool execution failed", cause: reason))

  defp bounded(result, limit) when is_integer(limit) and limit > 0 do
    if :erlang.external_size(result) <= limit,
      do: :ok,
      else:
        {:error,
         Error.new(:resource_conflict, "tool result exceeds output limit",
           details: %{limit: limit}
         )}
  end

  defp bounded(_result, _limit),
    do: {:error, Error.new(:validation, "output_limit must be positive")}
end
