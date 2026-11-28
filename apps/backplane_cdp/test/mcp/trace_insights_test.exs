defmodule Backplane.CDP.MCP.TraceInsightsTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.MCP.TraceInsights

  test "only reports measured timings and DOM counts for navigations in the traced page" do
    events = [
      %{
        name: "navigationStart",
        ts: 1,
        args: %{
          frame: "main",
          data: %{navigationId: "nav", documentLoaderURL: "https://example.test"}
        }
      },
      %{
        name: "ResourceReceiveResponse",
        ts: 2,
        args: %{
          data: %{
            frame: "main",
            requestId: "asset",
            timing: %{sendEnd: 0, receiveHeadersStart: 950}
          }
        }
      },
      %{
        name: "ResourceReceiveResponse",
        ts: 3,
        args: %{
          data: %{
            frame: "main",
            requestId: "nav",
            timing: %{sendEnd: 10, receiveHeadersStart: 55.5}
          }
        }
      },
      %{name: "DOMStats", ts: 4, args: %{data: %{frame: "other", totalElements: 99}}},
      %{name: "DOMStats", ts: 5, args: %{data: %{frame: "main", totalElements: 7}}}
    ]

    assert %{"NAVIGATION_0" => %{"DocumentLatency" => delay, "DOMSize" => "Total elements: 7"}} =
             TraceInsights.build(Formata.JSON.encode!(%{traceEvents: events}), "main")

    assert delay =~ "45.5 ms"
    assert %{} == TraceInsights.build(Formata.JSON.encode!(%{traceEvents: events}), "missing")
  end
end
