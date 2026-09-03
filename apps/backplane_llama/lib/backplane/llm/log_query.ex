defmodule Backplane.LLM.LogQuery do
  @moduledoc """
  Query helpers for persisted LLM proxy access records.
  """

  import Ecto.Query

  alias Backplane.LLM.ProxyRequest
  alias Backplane.Repo

  @type filters :: %{
          optional(:provider_id) => binary(),
          optional(:model) => binary(),
          optional(:since) => DateTime.t(),
          optional(:until) => DateTime.t(),
          optional(:outcome) => binary(),
          optional(:trace_id) => binary(),
          optional(:request_id) => binary()
        }

  @type list_opts :: %{
          optional(:limit) => pos_integer(),
          optional(:cursor) => {DateTime.t(), binary()}
        }

  @type aggregate_result :: %{
          total_requests: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          avg_latency_ms: non_neg_integer(),
          by_model: [
            %{
              model: binary(),
              requests: non_neg_integer(),
              input_tokens: non_neg_integer(),
              output_tokens: non_neg_integer()
            }
          ],
          by_status: %{binary() => non_neg_integer()}
        }

  @doc "Lists access records using keyset pagination on `(inserted_at, id)`."
  @spec list(filters(), list_opts()) :: [ProxyRequest.t()]
  def list(filters \\ %{}, opts \\ %{}) do
    limit = Map.get(opts, :limit, 50)
    cursor = Map.get(opts, :cursor)

    filters
    |> base_query()
    |> apply_cursor(cursor)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&with_virtual_model/1)
  end

  @doc "Gets a single access record by primary key."
  @spec get(binary()) :: ProxyRequest.t() | nil
  def get(id) do
    case Repo.get(ProxyRequest, id) do
      nil -> nil
      row -> with_virtual_model(row)
    end
  end

  @doc "Lists access records for a request ID."
  @spec list_by_request_id(String.t(), list_opts()) :: [ProxyRequest.t()]
  def list_by_request_id(request_id, opts \\ %{}) do
    list(%{request_id: request_id}, opts)
  end

  @doc "Lists access records for a trace ID."
  @spec list_by_trace_id(String.t(), list_opts()) :: [ProxyRequest.t()]
  def list_by_trace_id(trace_id, opts \\ %{}) do
    list(%{trace_id: trace_id}, opts)
  end

  @doc """
  Aggregates usage with optional filters.

  Returns the same shape as `Backplane.LLM.UsageQuery.aggregate/1`.
  """
  @spec aggregate(filters()) :: aggregate_result()
  def aggregate(filters \\ %{}) do
    base = base_query(filters)

    totals =
      base
      |> select([l], %{
        total_requests: count(l.id),
        total_input_tokens: sum(l.input_tokens),
        total_output_tokens: sum(l.output_tokens),
        avg_latency_ms: avg(l.duration_ms)
      })
      |> Repo.one()

    by_model =
      base
      |> group_by([l], l.requested_model)
      |> select([l], %{
        model: l.requested_model,
        requests: count(l.id),
        input_tokens: sum(l.input_tokens),
        output_tokens: sum(l.output_tokens)
      })
      |> order_by([l], l.requested_model)
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          model: row.model,
          requests: row.requests,
          input_tokens: row.input_tokens || 0,
          output_tokens: row.output_tokens || 0
        }
      end)

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

  defp base_query(filters) do
    from(l in ProxyRequest)
    |> maybe_filter_provider(filters[:provider_id])
    |> maybe_filter_model(filters[:model])
    |> maybe_filter_since(filters[:since])
    |> maybe_filter_until(filters[:until])
    |> maybe_filter_outcome(filters[:outcome])
    |> maybe_filter_trace(filters[:trace_id])
    |> maybe_filter_request(filters[:request_id])
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {inserted_at, id}) do
    where(
      query,
      [l],
      l.inserted_at < ^inserted_at or (l.inserted_at == ^inserted_at and l.id < ^id)
    )
  end

  defp maybe_filter_provider(query, nil), do: query
  defp maybe_filter_provider(query, id), do: where(query, [l], l.provider_id == ^id)

  defp maybe_filter_model(query, nil), do: query

  defp maybe_filter_model(query, model),
    do: where(query, [l], l.requested_model == ^model)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [l], l.inserted_at >= ^since)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [l], l.inserted_at <= ^until)

  defp maybe_filter_outcome(query, nil), do: query
  defp maybe_filter_outcome(query, outcome), do: where(query, [l], l.outcome == ^outcome)

  defp maybe_filter_trace(query, nil), do: query
  defp maybe_filter_trace(query, trace_id), do: where(query, [l], l.trace_id == ^trace_id)

  defp maybe_filter_request(query, nil), do: query
  defp maybe_filter_request(query, request_id), do: where(query, [l], l.request_id == ^request_id)

  defp with_virtual_model(%ProxyRequest{} = row) do
    %{row | model: row.requested_model}
  end

  defp round_or_zero(nil), do: 0

  defp round_or_zero(%Decimal{} = val) do
    val |> Decimal.to_float() |> round()
  end

  defp round_or_zero(val) when is_number(val), do: round(val)
end
