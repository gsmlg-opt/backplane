defmodule Backplane.Diagnostics.Correlation do
  @moduledoc "Read-only joins to audited proxy and Host trace records using explicit correlation identities."

  import Ecto.Query

  alias Backplane.AgentTraces.Event, as: LegacyTrace
  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Sources.Source
  alias Backplane.Repo

  @max_references 15

  @doc "Returns metadata-only references. A time match alone never links observations."
  def references(%Event{} = event) do
    request = get_in(event.body, ["correlation", "request_id"])
    span = get_in(event.body, ["correlation", "span_id"])

    proxy_references(event.trace_id, request, span) ++ legacy_references(event)
  end

  defp proxy_references(trace, request, span) when is_binary(trace) and is_binary(request) do
    roots = request_records("mcp_proxy_requests", "mcp_proxy", trace, request)
    llm = request_records("llm_logs", "llm_proxy", trace, request)
    llm ++ roots ++ tool_records(roots, trace, span)
  end

  defp proxy_references(_trace, _request, _span), do: []

  defp request_records(table, protocol, trace, request) do
    rows =
      Repo.all(
        from row in table,
          where:
            field(row, :trace_id) == ^trace and field(row, :request_id) == ^request and
              not is_nil(field(row, :event_id)),
          order_by: [desc: field(row, :inserted_at), desc: field(row, :event_id)],
          select: field(row, :event_id),
          limit: @max_references
      )

    Enum.map(
      rows,
      &%{"protocol" => protocol, "event_id" => &1, "request_id" => request, "trace_id" => trace}
    )
  end

  defp tool_records(roots, trace, span) when is_binary(span) and roots != [] do
    root_ids = Enum.map(roots, & &1["event_id"])

    rows =
      Repo.all(
        from row in "mcp_tool_calls",
          where:
            field(row, :trace_id) == ^trace and field(row, :span_id) == ^span and
              field(row, :mcp_request_id) in ^root_ids,
          order_by: [desc: field(row, :inserted_at), desc: field(row, :event_id)],
          select: field(row, :event_id),
          limit: @max_references
      )

    Enum.map(
      rows,
      &%{"protocol" => "mcp_tool_call", "event_id" => &1, "trace_id" => trace, "span_id" => span}
    )
  end

  defp tool_records(_roots, _trace, _span), do: []

  defp legacy_references(%Event{trace_id: trace, source_id: source_id}) when is_binary(trace) do
    case Repo.get(Source, source_id) do
      %Source{host_id: host} when not is_nil(host) ->
        Repo.all(
          from row in LegacyTrace,
            where: row.host_id == ^host and row.trace_id == ^trace,
            order_by: [desc: row.occurred_at, desc: row.agent_seq],
            select: %{
              "protocol" => "host_trace.v1",
              "host_id" => row.host_id,
              "agent_seq" => row.agent_seq,
              "trace_id" => row.trace_id,
              "event_type" => row.event,
              "observed_at" => row.occurred_at,
              "run_id" => "unknown",
              "version" => "unknown",
              "stack" => "unknown"
            },
            limit: @max_references
        )

      _ ->
        []
    end
  end

  defp legacy_references(_event), do: []
end
