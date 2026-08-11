defmodule Backplane.McpProtocol.Server.Modern.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Modern.Discovery
  alias Backplane.McpProtocol.Server.Modern.RequestContext

  defmodule DiscoveryServer do
    @moduledoc false
    def supported_protocol_versions do
      ["2025-11-25", "2026-07-28", "2026-07-28", "2099-01-01"]
    end

    def server_capabilities do
      %{
        :completion => %{vendor_mode: :fast},
        "tools" => %{listChanged: true},
        :tasks => %{"list" => %{}},
        :experimental => %{"com.example/feature" => %{nestedFlag: true}}
      }
    end

    def server_instructions, do: "Use the modern tools carefully."
  end

  defmodule NilInstructionsServer do
    @moduledoc false
    def supported_protocol_versions, do: ["2026-07-28"]
    def server_capabilities, do: %{}
    def server_instructions, do: nil
  end

  defmodule RaisingServer do
    @moduledoc false
    def supported_protocol_versions, do: raise("contained by executor")
    def server_capabilities, do: %{}
    def server_instructions, do: nil
  end

  test "returns raw discovery data with stable modern versions and normalized capabilities" do
    assert {:ok, result} = Discovery.execute(DiscoveryServer, request_context())

    assert result == %{
             "supportedVersions" => ["2026-07-28"],
             "capabilities" => %{
               "completions" => %{"vendor_mode" => "fast"},
               "tools" => %{"listChanged" => true},
               "experimental" => %{
                 "com.example/feature" => %{"nestedFlag" => true}
               }
             },
             "instructions" => "Use the modern tools carefully."
           }

    refute Map.has_key?(result, "resultType")
    refute Map.has_key?(result, "_meta")
    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "cacheScope")
    refute Map.has_key?(result, "serverInfo")
  end

  test "accepts a precomputed executor snapshot and omits nil instructions" do
    snapshot = %{
      supported_versions: ["2026-07-28"],
      capabilities: %{tools: %{}},
      instructions: nil
    }

    assert {:ok, result} = Discovery.execute(snapshot, request_context())
    assert result["supportedVersions"] == ["2026-07-28"]
    assert result["capabilities"] == %{"tools" => %{}}
    refute Map.has_key?(result, "instructions")
  end

  test "explicit modern and string capability keys win deterministic collisions" do
    snapshot = %{
      supported_versions: ["2026-07-28"],
      capabilities: %{
        :completion => %{source: :legacy},
        "completions" => %{"source" => "modern"},
        :tools => %{listChanged: false},
        "tools" => %{"listChanged" => true}
      },
      instructions: nil
    }

    assert {:ok, result} = Discovery.execute(snapshot, request_context())

    assert result["capabilities"] == %{
             "completions" => %{"source" => "modern"},
             "tools" => %{"listChanged" => true}
           }
  end

  test "returns a sanitized internal error for malformed discovery snapshots" do
    valid = %{
      supported_versions: ["2026-07-28"],
      capabilities: %{},
      instructions: nil
    }

    malformed = [
      %{valid | supported_versions: :invalid},
      %{valid | capabilities: []},
      %{valid | capabilities: %{"tools" => %{7 => true}}},
      %{valid | capabilities: %{"tools" => nil}},
      %{valid | capabilities: %{"com.example/custom" => self()}},
      %{valid | instructions: 42}
    ]

    for snapshot <- malformed do
      assert {:error, %{code: -32_603, reason: :internal_error, data: %{}}} =
               Discovery.execute(snapshot, request_context())
    end
  end

  test "omits nil module instructions" do
    assert {:ok, result} = Discovery.execute(NilInstructionsServer, request_context())
    refute Map.has_key?(result, "instructions")
  end

  test "lets module callback failures bubble to executor containment" do
    assert_raise RuntimeError, "contained by executor", fn ->
      Discovery.execute(RaisingServer, request_context())
    end
  end

  defp request_context do
    {:ok, profile} = Registry.profile("2026-07-28")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    {:ok, context} = RequestContext.build(profile, request, %{transport: :stdio})
    context
  end
end
