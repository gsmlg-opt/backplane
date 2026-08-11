defmodule Backplane.McpProtocol.Transport.RequestContextTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.Transport.RequestContext

  @max_safe_integer 9_007_199_254_740_991

  describe "new/4" do
    test "snapshots a modern request profile and lifecycle" do
      state = state(:modern, "2026-07-28", :discovering)
      params = %{"_meta" => %{"trace" => "abc"}}

      context = RequestContext.new("server/discover", params, state)

      assert context.era == :modern
      assert context.lifecycle == :per_request
      assert context.protocol_version == "2026-07-28"
      assert context.profile.version == "2026-07-28"
      assert context.method == "server/discover"
      assert context.params == params
      assert context.parameter_headers == %{}
      assert RequestContext.modern?(context)
    end

    test "uses the per-send legacy context after discovery fallback" do
      state = state(:legacy, "2025-03-26", :initializing)
      params = %{"protocolVersion" => "2025-03-26"}

      context = RequestContext.new("initialize", params, state)

      assert context.era == :legacy
      assert context.lifecycle == :initialize
      assert context.protocol_version == "2025-03-26"
      assert context.method == "initialize"
      refute RequestContext.modern?(context)
    end

    test "method inference keeps auto discovery modern and fallback initialize legacy" do
      auto_state = state(nil, "2026-07-28", :connecting)
      fallback_state = state(nil, "2025-03-26", :connecting)

      assert RequestContext.modern?(RequestContext.new("server/discover", %{}, auto_state))
      refute RequestContext.modern?(RequestContext.new("initialize", %{}, fallback_state))
    end
  end

  describe "parameter_headers/1" do
    test "normalizes primitive values into canonical lower-case header names" do
      context =
        RequestContext.new("tools/call", %{}, state(:modern, "2026-07-28", :ready),
          parameter_headers: %{
            "Mcp-Param-City" => "Paris",
            "MCP-PARAM-SHARD" => 42,
            "mcp-param-enabled" => true
          }
        )

      assert {:ok,
              %{
                "mcp-param-city" => "Paris",
                "mcp-param-shard" => "42",
                "mcp-param-enabled" => "true"
              }} = RequestContext.parameter_headers(context)
    end

    test "accepts JavaScript safe integer bounds and rejects values outside them" do
      assert {:ok, "9007199254740991"} = RequestContext.mirrored_value(@max_safe_integer)
      assert {:ok, "-9007199254740991"} = RequestContext.mirrored_value(-@max_safe_integer)

      assert {:error, :unsafe_integer} =
               RequestContext.mirrored_value(@max_safe_integer + 1)

      assert {:error, :unsafe_integer} =
               RequestContext.mirrored_value(-@max_safe_integer - 1)
    end

    test "base64 encodes unsafe ASCII, non-ASCII, sentinel, newline, and control values" do
      for value <- [
            " padded ",
            "München",
            "=?base64?already?=",
            "line\r\nbreak",
            <<0, 1, 31, 127>>
          ] do
        assert {:ok, "=?base64?" <> encoded} = RequestContext.mirrored_value(value)
        assert String.ends_with?(encoded, "?=")
        payload = binary_part(encoded, 0, byte_size(encoded) - 2)
        assert {:ok, ^value} = Base.decode64(payload)
      end
    end

    test "keeps empty strings and interior horizontal tabs in plain form" do
      assert {:ok, ""} = RequestContext.mirrored_value("")
      assert {:ok, "left\tright"} = RequestContext.mirrored_value("left\tright")
      assert {:ok, "=?BASE64?plain?="} = RequestContext.mirrored_value("=?BASE64?plain?=")
      assert {:ok, "=?base64?incomplete"} = RequestContext.mirrored_value("=?base64?incomplete")
    end

    test "omits nil and rejects unsupported values" do
      assert :omit = RequestContext.mirrored_value(nil)
      assert {:error, :unsupported_value} = RequestContext.mirrored_value(1.5)
      assert {:error, :unsupported_value} = RequestContext.mirrored_value(%{})
    end

    test "rejects invalid parameter names and case-insensitive collisions" do
      assert {:error, {:invalid_parameter_header, "bad header"}} =
               RequestContext.parameter_headers(%{"bad header" => "value"})

      assert {:error, {:invalid_parameter_header, "authorization"}} =
               RequestContext.parameter_headers(%{"authorization" => "value"})

      assert {:error, {:duplicate_parameter_header, "mcp-param-city"}} =
               RequestContext.parameter_headers(%{
                 "Mcp-Param-City" => "Paris",
                 "mcp-param-city" => "London"
               })
    end
  end

  defp state(era, version, status) do
    %State{
      client_info: %{"name" => "TestClient", "version" => "1.0.0"},
      capabilities: %{},
      protocol_version: version,
      negotiated_version: if(status == :ready, do: version),
      negotiation_status: status,
      era: era
    }
  end
end
