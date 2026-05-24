defmodule Backplane.Proxy.SSEParserTest do
  use ExUnit.Case, async: true

  alias Backplane.Proxy.SSEParser

  describe "parse/2" do
    test "returns empty list for empty input" do
      assert {[], ""} = SSEParser.parse("", "")
    end

    test "parses a single complete event" do
      chunk = "data: hello world\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert %SSEParser{event: "message", data: "hello world"} = event
    end

    test "accumulates partial frames across calls" do
      # First chunk: partial event, no double newline
      {events1, rest1} = SSEParser.parse("data: hel", "")
      assert events1 == []
      assert rest1 == "data: hel"

      # Second chunk: complete the event
      {events2, rest2} = SSEParser.parse("lo world\n\n", rest1)
      assert [%SSEParser{data: "hello world"}] = events2
      assert rest2 == ""
    end

    test "joins multi-line data with newlines" do
      chunk = "data: line1\ndata: line2\ndata: line3\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "line1\nline2\nline3"
    end

    test "handles CRLF line endings" do
      chunk = "data: hello\r\n\r\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "hello"
    end

    test "handles CR-only line endings" do
      chunk = "data: hello\r\r"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "hello"
    end

    test "extracts retry: values as integers" do
      chunk = "data: test\nretry: 3000\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.retry == 3000
      assert event.data == "test"
    end

    test "extracts id: field" do
      chunk = "id: 42\ndata: test\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.id == "42"
      assert event.data == "test"
    end

    test "ignores comment lines" do
      chunk = ": this is a comment\ndata: hello\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "hello"
    end

    test "defaults event type to message" do
      chunk = "data: test\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.event == "message"
    end

    test "sets custom event type" do
      chunk = "event: custom\ndata: test\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.event == "custom"
    end

    test "strips one leading space from field values" do
      # With space after colon
      chunk = "data: hello\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "hello"

      # Without space after colon
      chunk2 = "data:hello\n\n"
      assert {[event2], ""} = SSEParser.parse(chunk2, "")
      assert event2.data == "hello"

      # Two spaces: only strip one
      chunk3 = "data:  hello\n\n"
      assert {[event3], ""} = SSEParser.parse(chunk3, "")
      assert event3.data == " hello"
    end

    test "parses multiple events in one chunk" do
      chunk = "data: first\n\ndata: second\n\n"
      assert {[e1, e2], ""} = SSEParser.parse(chunk, "")
      assert e1.data == "first"
      assert e2.data == "second"
    end

    test "handles multiple events with partial remainder" do
      chunk = "data: first\n\ndata: second\n\ndata: partial"
      assert {[e1, e2], rest} = SSEParser.parse(chunk, "")
      assert e1.data == "first"
      assert e2.data == "second"
      assert rest == "data: partial"
    end

    test "ignores non-integer retry values" do
      chunk = "data: test\nretry: abc\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.retry == nil
      assert event.data == "test"
    end

    test "ignores unknown field names" do
      chunk = "data: test\nfoo: bar\nbaz: qux\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "test"
      assert event.event == "message"
    end

    test "skips events with no data lines" do
      chunk = "event: ping\n\n"
      assert {[], ""} = SSEParser.parse(chunk, "")
    end

    test "skips data-less events but emits data-having ones" do
      chunk = "event: ping\n\ndata: real\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "real"
    end

    test "handles field line with no value (just field name and colon)" do
      chunk = "data:\n\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == ""
    end

    test "handles mixed line endings in one chunk" do
      chunk = "data: a\r\ndata: b\rdata: c\n\r\n"
      assert {[event], ""} = SSEParser.parse(chunk, "")
      assert event.data == "a\nb\nc"
    end
  end
end
