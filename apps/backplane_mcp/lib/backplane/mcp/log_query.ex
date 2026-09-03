defmodule Backplane.MCP.LogQuery do
  @moduledoc """
  Query helpers for persisted MCP root proxy access records.
  """

  import Ecto.Query

  alias Backplane.MCP.{ProxyRequest, ToolCall}
  alias Backplane.Repo

  @type filters :: %{
          optional(:client_id) => binary(),
          optional(:operation) => binary(),
          optional(:rpc_method) => binary(),
          optional(:since) => DateTime.t(),
          optional(:until) => DateTime.t(),
          optional(:outcome) => binary(),
          optional(:trace_id) => binary(),
          optional(:request_id) => binary(),
          optional(:era) => binary(),
          optional(:auth_kind) => binary()
        }

  @type list_opts :: %{
          optional(:limit) => pos_integer(),
          optional(:cursor) => {DateTime.t(), binary()}
        }

  @type aggregate_result :: %{
          total_requests: non_neg_integer(),
          avg_duration_ms: non_neg_integer(),
          by_operation: [%{operation: binary(), requests: non_neg_integer()}],
          by_rpc_method: [%{rpc_method: binary(), requests: non_neg_integer()}],
          by_outcome: %{binary() => non_neg_integer()}
        }

  @doc "Lists access records using keyset pagination on `(inserted_at, id)`."
  @spec list(filters(), list_opts()) :: [ProxyRequest.t()]
  def list(filters \\ %{}, opts \\ %{}) do
    limit = Map.get(opts, :limit, 50)
    cursor = Map.get(opts, :cursor)

    filters
    |> base_query()
    |> apply_cursor(cursor)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Gets a single access record by primary key."
  @spec get(binary()) :: ProxyRequest.t() | nil
  def get(id), do: Repo.get(ProxyRequest, id)

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

  @doc "Lists child tool-call records with optional filters and keyset pagination."
  @spec list_tool_calls(map(), list_opts()) :: [ToolCall.t()]
  def list_tool_calls(filters \\ %{}, opts \\ %{}) do
    limit = Map.get(opts, :limit, 50)
    cursor = Map.get(opts, :cursor)

    filters
    |> tool_call_base_query()
    |> apply_tool_call_cursor(cursor)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Lists tool-call child records for an MCP root request ID."
  @spec list_tool_calls_for_request(String.t(), list_opts()) :: [ToolCall.t()]
  def list_tool_calls_for_request(mcp_request_id, opts \\ %{}) do
    list_tool_calls(%{mcp_request_id: mcp_request_id}, opts)
  end

  @doc "Lists tool-call child records for a trace ID."
  @spec list_tool_calls_for_trace(String.t(), list_opts()) :: [ToolCall.t()]
  def list_tool_calls_for_trace(trace_id, opts \\ %{}) do
    list_tool_calls(%{trace_id: trace_id}, opts)
  end

  @doc "Aggregates MCP root request usage with optional filters."
  @spec aggregate(filters()) :: aggregate_result()
  def aggregate(filters \\ %{}) do
    base = base_query(filters)

    totals =
      base
      |> select([r], %{
        total_requests: count(r.id),
        avg_duration_ms: avg(r.duration_ms)
      })
      |> Repo.one()

    by_operation =
      base
      |> group_by([r], r.operation)
      |> select([r], %{operation: r.operation, requests: count(r.id)})
      |> order_by([r], r.operation)
      |> Repo.all()

    by_rpc_method =
      base
      |> where([r], not is_nil(r.rpc_method))
      |> group_by([r], r.rpc_method)
      |> select([r], %{rpc_method: r.rpc_method, requests: count(r.id)})
      |> order_by([r], r.rpc_method)
      |> Repo.all()

    by_outcome =
      base
      |> group_by([r], r.outcome)
      |> select([r], {r.outcome, count(r.id)})
      |> Repo.all()
      |> Enum.into(%{})

    %{
      total_requests: totals.total_requests || 0,
      avg_duration_ms: round_or_zero(totals.avg_duration_ms),
      by_operation: by_operation,
      by_rpc_method: by_rpc_method,
      by_outcome: by_outcome
    }
  end

  defp base_query(filters) do
    from(r in ProxyRequest)
    |> maybe_filter_client(filters[:client_id])
    |> maybe_filter_operation(filters[:operation])
    |> maybe_filter_rpc_method(filters[:rpc_method])
    |> maybe_filter_since(filters[:since])
    |> maybe_filter_until(filters[:until])
    |> maybe_filter_outcome(filters[:outcome])
    |> maybe_filter_trace(filters[:trace_id])
    |> maybe_filter_request(filters[:request_id])
    |> maybe_filter_era(filters[:era])
    |> maybe_filter_auth_kind(filters[:auth_kind])
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {inserted_at, id}) do
    where(
      query,
      [r],
      r.inserted_at < ^inserted_at or (r.inserted_at == ^inserted_at and r.id < ^id)
    )
  end

  defp maybe_filter_client(query, nil), do: query
  defp maybe_filter_client(query, id), do: where(query, [r], r.client_id == ^id)

  defp maybe_filter_operation(query, nil), do: query
  defp maybe_filter_operation(query, operation), do: where(query, [r], r.operation == ^operation)

  defp maybe_filter_rpc_method(query, nil), do: query
  defp maybe_filter_rpc_method(query, method), do: where(query, [r], r.rpc_method == ^method)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [r], r.inserted_at >= ^since)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [r], r.inserted_at <= ^until)

  defp maybe_filter_outcome(query, nil), do: query
  defp maybe_filter_outcome(query, outcome), do: where(query, [r], r.outcome == ^outcome)

  defp maybe_filter_trace(query, nil), do: query
  defp maybe_filter_trace(query, trace_id), do: where(query, [r], r.trace_id == ^trace_id)

  defp maybe_filter_request(query, nil), do: query
  defp maybe_filter_request(query, request_id), do: where(query, [r], r.request_id == ^request_id)

  defp maybe_filter_era(query, nil), do: query
  defp maybe_filter_era(query, era), do: where(query, [r], r.era == ^era)

  defp maybe_filter_auth_kind(query, nil), do: query
  defp maybe_filter_auth_kind(query, kind), do: where(query, [r], r.auth_kind == ^kind)

  defp tool_call_base_query(filters) do
    from(t in ToolCall)
    |> maybe_filter_tool_request(filters[:mcp_request_id])
    |> maybe_filter_tool_trace(filters[:trace_id])
    |> maybe_filter_tool_name(filters[:tool_name])
    |> maybe_filter_upstream_name(filters[:upstream_name])
    |> maybe_filter_tool_since(filters[:since])
    |> maybe_filter_tool_until(filters[:until])
    |> maybe_filter_tool_outcome(filters[:outcome])
  end

  defp apply_tool_call_cursor(query, nil), do: query

  defp apply_tool_call_cursor(query, {inserted_at, id}) do
    where(
      query,
      [t],
      t.inserted_at < ^inserted_at or (t.inserted_at == ^inserted_at and t.id < ^id)
    )
  end

  defp maybe_filter_tool_request(query, nil), do: query

  defp maybe_filter_tool_request(query, request_id),
    do: where(query, [t], t.mcp_request_id == ^request_id)

  defp maybe_filter_tool_trace(query, nil), do: query
  defp maybe_filter_tool_trace(query, trace_id), do: where(query, [t], t.trace_id == ^trace_id)

  defp maybe_filter_tool_name(query, nil), do: query
  defp maybe_filter_tool_name(query, name), do: where(query, [t], t.tool_name == ^name)

  defp maybe_filter_upstream_name(query, nil), do: query

  defp maybe_filter_upstream_name(query, name),
    do: where(query, [t], t.upstream_name == ^name)

  defp maybe_filter_tool_since(query, nil), do: query
  defp maybe_filter_tool_since(query, since), do: where(query, [t], t.inserted_at >= ^since)

  defp maybe_filter_tool_until(query, nil), do: query
  defp maybe_filter_tool_until(query, until), do: where(query, [t], t.inserted_at <= ^until)

  defp maybe_filter_tool_outcome(query, nil), do: query
  defp maybe_filter_tool_outcome(query, outcome), do: where(query, [t], t.outcome == ^outcome)

  defp round_or_zero(nil), do: 0

  defp round_or_zero(%Decimal{} = val) do
    val |> Decimal.to_float() |> round()
  end

  defp round_or_zero(val) when is_number(val), do: round(val)
end
