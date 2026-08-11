defmodule Backplane.McpProtocol.Server.Modern.HeadersTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Component.Tool
  alias Backplane.McpProtocol.Server.Modern.Headers

  setup do
    {:ok, profile} = Registry.profile("2026-07-28")
    %{profile: profile}
  end

  test "stdio has no HTTP header requirements", %{profile: profile} do
    assert :ok = Headers.validate(profile, request("tools/list"), %{transport: :stdio, headers: %{}})
  end

  test "validates standard HTTP headers case-insensitively and values case-sensitively", %{profile: profile} do
    context = %{
      transport: :http,
      headers: %{
        "MCP-PROTOCOL-VERSION" => "2026-07-28",
        "mCp-MeThOd" => "tools/call",
        "MCP-NAME" => "weather"
      }
    }

    assert :ok = Headers.validate(profile, request("tools/call", %{"name" => "weather"}), context)

    assert {:error, %{code: -32_020}} =
             Headers.validate(
               profile,
               request("tools/call", %{"name" => "Weather"}),
               context
             )
  end

  test "requires the protocol, method, and named-operation headers for HTTP", %{profile: profile} do
    request = request("resources/read", %{"uri" => "file:///readme"})

    for headers <- [
          %{"mcp-method" => "resources/read", "mcp-name" => "file:///readme"},
          %{"mcp-protocol-version" => "2026-07-28", "mcp-name" => "file:///readme"},
          %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => "resources/read"}
        ] do
      assert {:error, %{code: -32_020}} =
               Headers.validate(profile, request, %{transport: :http, headers: headers})
    end
  end

  test "rejects duplicate standard HTTP routing headers case-insensitively", %{profile: profile} do
    request = request("tools/call", %{"name" => "weather"})

    headers = [
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "tools/call"},
      {"mcp-name", "weather"}
    ]

    for {name, value} <- headers do
      assert {:error, %{code: -32_020}} =
               Headers.validate(profile, request, %{
                 transport: :http,
                 req_headers: headers ++ [{String.upcase(name), value}]
               })
    end
  end

  test "header/body disagreement wins over unsupported version classification", %{profile: profile} do
    request =
      "tools/list"
      |> request()
      |> put_in(
        ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
        "2099-01-01"
      )

    assert {:error, %{code: -32_020}} =
             Headers.validate(profile, request, %{
               transport: :http,
               headers: %{
                 "mcp-protocol-version" => "2026-07-28",
                 "mcp-method" => "tools/list"
               }
             })
  end

  test "decodes only the exact lowercase Base64 sentinel for Mcp-Name", %{profile: profile} do
    name = "weather 世界"
    encoded = "=?base64?#{Base.encode64(name)}?="
    request = request("tools/call", %{"name" => name})

    assert :ok =
             Headers.validate(profile, request, %{
               transport: :http,
               headers: standard_headers("tools/call", encoded)
             })

    assert {:error, %{code: -32_020}} =
             Headers.validate(profile, request, %{
               transport: :http,
               headers: standard_headers("tools/call", "=?BASE64?#{Base.encode64(name)}?=")
             })
  end

  test "validates statically reachable primitive tool parameter mirrors numerically" do
    tool = %Tool{
      name: "route",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "tenant" => %{"type" => "string", "x-mcp-header" => "Tenant"},
          "route" => %{
            "type" => "object",
            "properties" => %{
              "enabled" => %{"type" => "boolean", "x-mcp-header" => "Enabled"},
              "shard" => %{"type" => "integer", "x-mcp-header" => "Shard"}
            }
          }
        }
      }
    }

    request =
      request("tools/call", %{
        "name" => "route",
        "arguments" => %{"tenant" => "Acme 世界", "route" => %{"enabled" => true, "shard" => 42}}
      })

    headers = %{
      "MCP-PARAM-TENANT" => "=?base64?#{Base.encode64("Acme 世界")}?=",
      "mcp-param-enabled" => "true",
      "Mcp-Param-Shard" => "42.0"
    }

    assert :ok = Headers.validate_tool_params(tool, request, %{transport: :http, headers: headers})

    assert {:error, %{code: -32_020}} =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               headers: Map.put(headers, "MCP-PARAM-TENANT", "acme 世界")
             })

    assert {:error, %{code: -32_020}} =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               headers: Map.put(headers, "Mcp-Param-Shard", "42.0000000000000001")
             })
  end

  test "requires recognized mirrors when values are present but ignores unknown headers" do
    tool = tool_with_header("region", "string", "Region")
    request = request("tools/call", %{"name" => "route", "arguments" => %{"region" => "west"}})

    assert {:error, %{code: -32_020}} =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               headers: %{"mcp-param-unknown" => "ignored"}
             })
  end

  test "rejects duplicate recognized parameter mirrors but ignores duplicate unknown mirrors" do
    tool = tool_with_header("region", "string", "Region")
    request = request("tools/call", %{"name" => "route", "arguments" => %{"region" => "west"}})

    assert {:error, %{code: -32_020}} =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               req_headers: [
                 {"mcp-param-region", "west"},
                 {"MCP-PARAM-REGION", "west"}
               ]
             })

    assert :ok =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               req_headers: [
                 {"mcp-param-region", "west"},
                 {"mcp-param-unknown", "first"},
                 {"MCP-PARAM-UNKNOWN", "second"}
               ]
             })
  end

  test "null and missing values require omission while unknown headers are ignored" do
    tool = tool_with_header("region", "string", "Region")

    for arguments <- [%{}, %{"region" => nil}] do
      request = request("tools/call", %{"name" => "route", "arguments" => arguments})

      assert :ok =
               Headers.validate_tool_params(tool, request, %{
                 transport: :http,
                 headers: %{"mcp-param-unknown" => "ignored"}
               })

      assert {:error, %{code: -32_020}} =
               Headers.validate_tool_params(tool, request, %{
                 transport: :http,
                 headers: %{"mcp-param-region" => "unexpected"}
               })

      assert :ok = Headers.validate_tool_params(tool, request, %{transport: :stdio, headers: %{}})
    end
  end

  test "does not recognize number, unsafe integer, or dynamically reachable annotations" do
    tool = %Tool{
      name: "route",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "score" => %{"type" => "number", "x-mcp-header" => "Score"},
          "huge" => %{"type" => "integer", "x-mcp-header" => "Huge"},
          "items" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "region" => %{"type" => "string", "x-mcp-header" => "Region"}
              }
            }
          }
        }
      }
    }

    request =
      request("tools/call", %{
        "name" => "route",
        "arguments" => %{
          "score" => 1.5,
          "huge" => 9_007_199_254_740_992,
          "items" => [%{"region" => "west"}]
        }
      })

    assert {:error, %{code: -32_020}} =
             Headers.validate_tool_params(tool, request, %{
               transport: :http,
               headers: %{"mcp-param-huge" => "9007199254740992"}
             })

    safe_request = put_in(request, ["params", "arguments", "huge"], nil)
    assert :ok = Headers.validate_tool_params(tool, safe_request, %{transport: :http, headers: %{}})
  end

  defp request(method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp standard_headers(method, name) do
    %{
      "mcp-protocol-version" => "2026-07-28",
      "mcp-method" => method,
      "mcp-name" => name
    }
  end

  defp tool_with_header(property, type, header) do
    %Tool{
      name: "route",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          property => %{"type" => type, "x-mcp-header" => header}
        }
      }
    }
  end
end
