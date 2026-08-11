defmodule Backplane.McpProtocol.Protocol.ProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.Profile

  test "requires the fields that define a protocol era" do
    assert %Profile{
             version: "2026-07-28",
             era: :modern,
             lifecycle: :per_request,
             request_methods: ["server/discover"],
             notification_methods: ["notifications/cancelled"],
             features: [],
             cacheable_methods: [],
             named_methods: [],
             extensions: %{}
           } = %Profile{
             version: "2026-07-28",
             era: :modern,
             lifecycle: :per_request,
             request_methods: ["server/discover"],
             notification_methods: ["notifications/cancelled"]
           }
  end
end
