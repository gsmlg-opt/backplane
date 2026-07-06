defmodule Backplane.HostAgent.TraceTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Trace

  test "formats and parses traceparent with incoming span as parent" do
    ctx = Trace.new_ctx()
    traceparent = Trace.to_traceparent(ctx)

    assert {:ok, parsed} = Trace.parse_traceparent(traceparent)
    assert parsed.trace_id == ctx.trace_id
    assert parsed.parent_id == ctx.span_id
    assert parsed.span_id != ctx.span_id
    assert Trace.to_traceparent(parsed) =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/
  end

  test "rejects invalid traceparent values" do
    assert Trace.parse_traceparent(nil) == :error
    assert Trace.parse_traceparent("00-not-hex-01") == :error

    assert Trace.parse_traceparent("00-ABCDEFABCDEFABCDEFABCDEFABCDEFAB-1234567890abcdef-01") ==
             :error
  end

  test "with_ctx restores the previous context" do
    root = Trace.new_ctx()
    child = Trace.child_ctx(root)

    Trace.with_ctx(root, fn ->
      assert Trace.current() == root

      Trace.with_ctx(child, fn ->
        assert Trace.current() == child
      end)

      assert Trace.current() == root
    end)

    assert Trace.current() == nil
  end
end
