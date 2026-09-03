defmodule Backplane.Observability.ContextPlug do
  @moduledoc """
  Establishes request and trace correlation at the HTTP ingress.

  Insert immediately after `Plug.RequestId` and before proxy plugs.
  """

  @behaviour Plug

  require Logger

  alias Backplane.Observability.Context

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id = request_id(conn)
    {trace_id, parent_span_id} = trace_context(conn)

    context =
      Context.root(
        request_id: request_id,
        trace_id: trace_id,
        parent_span_id: parent_span_id
      )

    Logger.metadata(Context.logger_metadata(context))

    Context.put(conn, context)
  end

  defp request_id(conn) do
    conn.assigns[:request_id] ||
      conn |> Plug.Conn.get_req_header("x-request-id") |> List.first() ||
      Backplane.Observability.Id.request_id()
  end

  defp trace_context(conn) do
    case conn |> Plug.Conn.get_req_header("traceparent") |> List.first() do
      nil ->
        {Backplane.Observability.Id.trace_id(), nil}

      header ->
        case Context.parse_traceparent(header) do
          {:ok, {trace_id, parent_span_id}} -> {trace_id, parent_span_id}
          :invalid -> {Backplane.Observability.Id.trace_id(), nil}
        end
    end
  end
end
