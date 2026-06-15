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
end
