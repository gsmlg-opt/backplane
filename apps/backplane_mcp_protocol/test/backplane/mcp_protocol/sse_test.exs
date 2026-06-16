defmodule Backplane.McpProtocol.SseTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Sse

  test "encodes and parses message events" do
    encoded = Sse.encode("message", %{"ok" => true})

    assert encoded =~ "event: message\n"
    assert encoded =~ "data: {"

    assert {[%{event: "message", data: data}], ""} = Sse.parse(encoded)
    assert Jason.decode!(data) == %{"ok" => true}
  end

  test "parses data-only events with the default message event type" do
    assert {[%{event: "message", data: "hello"}], ""} = Sse.parse("data: hello\n\n")
  end

  test "parses CRLF events with multiline data, id, and retry" do
    frame = "id: 42\r\nevent: custom\r\nretry: 3000\r\ndata: first\r\ndata: second\r\n\r\n"

    assert {[%{event: "custom", data: "first\nsecond", id: "42", retry: 3000}], ""} =
             Sse.parse(frame)
  end

  test "keeps an incomplete frame as the next buffer" do
    assert {[], "event: message\ndata: half"} = Sse.parse("event: message\ndata: half")
  end
end
