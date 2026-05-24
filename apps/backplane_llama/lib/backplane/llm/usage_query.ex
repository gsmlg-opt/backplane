defmodule Backplane.LLM.UsageQuery do
  @moduledoc """
  Aggregation queries over LLM usage logs.

  Provides `aggregate/1` which summarises usage data with optional filters.
  """

  import Ecto.Query

  alias Backplane.LLM.UsageLog
  alias Backplane.Repo

  @type filters :: %{
          optional(:provider_id) => binary(),
          optional(:model) => binary(),
          optional(:since) => DateTime.t(),
          optional(:until) => DateTime.t()
        }

  @type aggregate_result :: %{
          total_requests: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          avg_latency_ms: non_neg_integer(),
          by_model: [%{model: binary(), requests: non_neg_integer(), input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}],
          by_status: %{binary() => non_neg_integer()}
        }

  @doc """
  Aggregate usage logs with optional filters.

  Filters:
    - `:provider_id` — filter by provider UUID
    - `:model` — filter by model name
    - `:since` — only include logs after this DateTime
    - `:until` — only include logs before this DateTime

  Returns aggregated stats including totals, per-model breakdown, and per-status counts.
  """
  @spec aggregate(filters()) :: aggregate_result()
  def aggregate(filters \\ %{}) do
    base = build_base_query(filters)

    # Overall totals
    totals =
      base
      |> select([l], %{
        total_requests: count(l.id),
        total_input_tokens: sum(l.input_tokens),
        total_output_tokens: sum(l.output_tokens),
        avg_latency_ms: avg(l.latency_ms)
      })
      |> Repo.one()

    # Per-model breakdown
    by_model =
      base
      |> group_by([l], l.model)
      |> select([l], %{
        model: l.model,
        requests: count(l.id),
        input_tokens: sum(l.input_tokens),
        output_tokens: sum(l.output_tokens)
      })
      |> order_by([l], l.model)
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          model: row.model,
          requests: row.requests,
          input_tokens: row.input_tokens || 0,
          output_tokens: row.output_tokens || 0
        }
      end)

    # Per-status breakdown
    by_status =
      base
      |> where([l], not is_nil(l.status))
      |> group_by([l], l.status)
      |> select([l], {l.status, count(l.id)})
      |> Repo.all()
      |> Enum.into(%{}, fn {status, count} -> {to_string(status), count} end)

    %{
      total_requests: totals.total_requests || 0,
      total_input_tokens: totals.total_input_tokens || 0,
      total_output_tokens: totals.total_output_tokens || 0,
      avg_latency_ms: round_or_zero(totals.avg_latency_ms),
      by_model: by_model,
      by_status: by_status
    }
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_base_query(filters) do
    query = from(l in UsageLog)

    query
    |> maybe_filter_provider(filters[:provider_id])
    |> maybe_filter_model(filters[:model])
    |> maybe_filter_since(filters[:since])
    |> maybe_filter_until(filters[:until])
  end

  defp maybe_filter_provider(query, nil), do: query
  defp maybe_filter_provider(query, id), do: where(query, [l], l.provider_id == ^id)

  defp maybe_filter_model(query, nil), do: query
  defp maybe_filter_model(query, model), do: where(query, [l], l.model == ^model)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [l], l.inserted_at >= ^since)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [l], l.inserted_at <= ^until)

  defp round_or_zero(nil), do: 0

  defp round_or_zero(%Decimal{} = val) do
    val |> Decimal.to_float() |> round()
  end

  defp round_or_zero(val) when is_number(val), do: round(val)
end
