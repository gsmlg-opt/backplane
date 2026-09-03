defmodule Backplane.Observability.ContextPlugTest do
  use ExUnit.Case, async: true

  alias Backplane.Observability.{Context, ContextPlug}

  test "assigns request and generated trace context" do
    conn =
      Plug.Test.conn(:get, "/v1/models")
      |> Plug.Conn.put_req_header("x-request-id", "req-header-1")
      |> ContextPlug.call([])

    assert %Context{request_id: "req-header-1", trace_id: trace_id, span_id: span_id} =
             Context.get(conn)

    assert byte_size(trace_id) == 32
    assert byte_size(span_id) == 16
  end

  test "reuses inbound traceparent context" do
    trace_id = String.duplicate("c", 32)
    parent_id = String.duplicate("d", 16)

    conn =
      Plug.Test.conn(:get, "/mcp")
      |> Plug.Conn.put_req_header("traceparent", "00-#{trace_id}-#{parent_id}-01")
      |> ContextPlug.call([])

    assert %Context{trace_id: ^trace_id, parent_span_id: ^parent_id} = Context.get(conn)
  end
end
