defmodule Backplane.Observability.ContextTest do
  use ExUnit.Case, async: true

  alias Backplane.Observability.Context

  test "builds child spans linked to the parent trace" do
    root = Context.root(request_id: "req-1", trace_id: "trace-1", span_id: "span-root")
    child = Context.child(root, span_id: "span-child")

    assert child.request_id == "req-1"
    assert child.trace_id == "trace-1"
    assert child.span_id == "span-child"
    assert child.parent_span_id == "span-root"
  end

  test "parses valid W3C traceparent headers" do
    trace_id = String.duplicate("a", 32)
    parent_id = String.duplicate("b", 16)

    assert Context.parse_traceparent("00-#{trace_id}-#{parent_id}-01") ==
             {:ok, {trace_id, parent_id}}
  end

  test "rejects invalid traceparent headers" do
    assert Context.parse_traceparent("invalid") == :invalid
    assert Context.parse_traceparent("00-short-span-01") == :invalid
  end

  test "stores context on a Plug connection" do
    conn =
      Plug.Test.conn(:get, "/health")
      |> Context.put(Context.root(request_id: "req-2", trace_id: "trace-2", span_id: "span-2"))

    assert %Context{request_id: "req-2", trace_id: "trace-2"} = Context.get(conn)
  end
end
