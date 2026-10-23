defmodule Backplane.McpProtocol.Transport.StatusTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Transport.SSE
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Stream

  test "HTTP transport diagnostics hide headers and transport options without changing state" do
    secret = "http-state-secret-57bf"

    state = %{
      headers: %{"authorization" => secret},
      headers_provider: fn -> {:ok, %{"authorization" => secret}} end,
      http_options: [proxy_headers: [{"authorization", secret}]],
      transport_opts: [headers: [{"x-api-key", secret}]],
      session_id: "diagnostic-session"
    }

    for transport <- [SSE, StreamableHTTP] do
      formatted = transport.format_status(%{state: state, reason: :example_failure})
      refute inspect(formatted, limit: :infinity) =~ secret
      assert formatted.state.session_id == "diagnostic-session"
      assert formatted.reason == :example_failure
      assert state.headers["authorization"] == secret
    end
  end

  test "request-scoped stream diagnostics hide its nested request configuration" do
    state = %Stream.State{
      subscription_id: "diagnostic-subscription",
      request: %{headers: %{"authorization" => "stream-state-secret-57bf"}}
    }

    formatted = Stream.format_status(%{state: state})
    refute inspect(formatted, limit: :infinity) =~ "stream-state-secret-57bf"
    assert formatted.state.subscription_id == "diagnostic-subscription"
    assert state.request.headers["authorization"] == "stream-state-secret-57bf"
  end
end
