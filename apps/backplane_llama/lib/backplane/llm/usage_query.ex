defmodule Backplane.LLM.UsageQuery do
  @moduledoc """
  Compatibility facade over `Backplane.LLM.LogQuery`.
  """

  alias Backplane.LLM.LogQuery

  @type filters :: LogQuery.filters()
  @type aggregate_result :: LogQuery.aggregate_result()
  @type daily_tokens_result :: LogQuery.daily_tokens_result()

  @doc "Returns daily token usage for the 30 UTC calendar days ending on today."
  @spec daily_tokens(Date.t()) :: daily_tokens_result()
  def daily_tokens(today \\ Date.utc_today()), do: LogQuery.daily_tokens(today)

  @doc "Aggregate usage logs with optional filters."
  @spec aggregate(filters()) :: aggregate_result()
  def aggregate(filters \\ %{}), do: LogQuery.aggregate(filters)
end
