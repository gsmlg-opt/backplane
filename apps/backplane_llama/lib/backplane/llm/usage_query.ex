defmodule Backplane.LLM.UsageQuery do
  @moduledoc """
  Compatibility facade over `Backplane.LLM.LogQuery`.
  """

  alias Backplane.LLM.LogQuery

  @type filters :: LogQuery.filters()
  @type aggregate_result :: LogQuery.aggregate_result()

  @doc "Aggregate usage logs with optional filters."
  @spec aggregate(filters()) :: aggregate_result()
  def aggregate(filters \\ %{}), do: LogQuery.aggregate(filters)
end
