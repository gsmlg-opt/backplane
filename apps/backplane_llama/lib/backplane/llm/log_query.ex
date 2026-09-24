defmodule Backplane.LLM.LogQuery do
  @moduledoc """
  Query helpers for persisted LLM proxy access records.
  """

  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.LLM.ProxyRequest
  alias Backplane.LLM.Provider
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
          by_provider: [
            %{
              provider: binary(),
              requests: non_neg_integer(),
              input_tokens: non_neg_integer(),
              cached_tokens: non_neg_integer(),
              output_tokens: non_neg_integer(),
              alias_calls: non_neg_integer()
            }
          ],
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
    |> with_client_name()
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&with_virtual_model/1)
  end

  @doc "Gets a single access record by primary key."
  @spec get(binary()) :: ProxyRequest.t() | nil
  def get(id) do
    case ProxyRequest
         |> where([l], l.id == ^id)
         |> with_client_name()
         |> Repo.one() do
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

    by_provider =
      base
      |> join(:left, [l], p in Provider, on: p.id == l.provider_id)
      |> group_by(
        [l, p],
        fragment("coalesce(nullif(?, ''), ?, 'Unknown')", l.provider_name, p.name)
      )
      |> select([l, p], %{
        provider: fragment("coalesce(nullif(?, ''), ?, 'Unknown')", l.provider_name, p.name),
        requests: count(l.id),
        input_tokens: sum(l.input_tokens),
        cached_tokens: sum(l.cached_tokens),
        output_tokens: sum(l.output_tokens),
        alias_calls:
          fragment(
            "count(*) filter (where ? is not null and ? is not null and ? <> ? and ? <> concat_ws('/', coalesce(nullif(?, ''), ?), ?))",
            l.requested_model,
            l.resolved_model,
            l.requested_model,
            l.resolved_model,
            l.requested_model,
            l.provider_name,
            p.name,
            l.resolved_model
          )
      })
      |> order_by([l, p],
        asc: fragment("coalesce(nullif(?, ''), ?, 'Unknown')", l.provider_name, p.name)
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          provider: row.provider,
          requests: row.requests,
          input_tokens: row.input_tokens || 0,
          cached_tokens: row.cached_tokens || 0,
          output_tokens: row.output_tokens || 0,
          alias_calls: row.alias_calls || 0
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
      by_provider: by_provider,
      by_model: by_model,
      by_status: by_status
    }
  end

  @doc "Aggregates persisted LLM usage by client ID and requested model."
  @spec aggregate_by_client() :: %{optional(binary()) => map()}
  def aggregate_by_client do
    from(l in ProxyRequest,
      where: not is_nil(l.client_id),
      group_by: [l.client_id, l.requested_model],
      select:
        {l.client_id, l.requested_model, count(l.id), sum(l.input_tokens), sum(l.cached_tokens),
         sum(l.output_tokens)}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {client_id, rows} ->
      models =
        Enum.map(rows, fn {_id, model, requests, input_tokens, cached_tokens, output_tokens} ->
          %{
            model: model || "Unknown",
            requests: requests,
            input_tokens: input_tokens || 0,
            cached_tokens: cached_tokens || 0,
            output_tokens: output_tokens || 0
          }
        end)
        |> Enum.sort_by(& &1.model)

      {client_id, %{requests: Enum.sum(Enum.map(models, & &1.requests)), models: models}}
    end)
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

  defp with_client_name(query) do
    query
    |> join(:left, [l], client in Client, on: client.id == l.client_id)
    |> select_merge([_l, client], %{client_name: client.name})
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
