defmodule Backplane.McpProtocol.Client.CatalogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.Catalog
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers

  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @protocol_version_key "io.modelcontextprotocol/protocolVersion"

  defmodule CaptureHTTP do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:send, encoded, _timeout, request_context}, _from, owner) do
      send(owner, {:http_send, encoded, request_context})
      {:reply, :ok, owner}
    end
  end

  test "compiles statically reachable primitive annotations and safely projects exact argument paths" do
    catalog =
      Catalog.compile([
        tool("weather", %{
          "city" => %{"type" => "string", "x-mcp-header" => "City"},
          "options" => %{
            "type" => "object",
            "properties" => %{
              "units" => %{"type" => "string", "x-mcp-header" => "Units"},
              "enabled" => %{"type" => "boolean", "x-mcp-header" => "Enabled"},
              "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"}
            }
          }
        })
      ])

    assert [%{"name" => "weather"}] = Enum.map(Catalog.tools(catalog), &Map.take(&1, ["name"]))

    assert {:ok,
            %{
              "Mcp-Param-City" => "Paris",
              "Mcp-Param-Enabled" => false,
              "Mcp-Param-Limit" => 42,
              "Mcp-Param-Units" => "metric"
            }} =
             Catalog.parameter_headers(catalog, "weather", %{
               "city" => "Paris",
               "options" => %{"units" => "metric", "enabled" => false, "limit" => 42}
             })

    assert {:ok, %{"Mcp-Param-City" => ""}} =
             Catalog.parameter_headers(catalog, "weather", %{"city" => ""})

    assert {:ok, %{}} = Catalog.parameter_headers(catalog, "weather", %{"city" => nil})
    assert {:ok, %{}} = Catalog.parameter_headers(catalog, "weather", %{})

    assert {:ok, %{"Mcp-Param-City" => "line\r\nbreak"}} =
             Catalog.parameter_headers(catalog, "weather", %{"city" => "line\r\nbreak"})

    for boundary <- [9_007_199_254_740_991, -9_007_199_254_740_991] do
      assert {:ok, %{"Mcp-Param-Limit" => ^boundary}} =
               Catalog.parameter_headers(catalog, "weather", %{
                 "options" => %{"limit" => boundary}
               })
    end

    for unsafe <- [9_007_199_254_740_992, -9_007_199_254_740_992] do
      assert {:ok, %{"Mcp-Param-Limit" => ^unsafe}} =
               Catalog.parameter_headers(catalog, "weather", %{"options" => %{"limit" => unsafe}})
    end
  end

  test "normalizes argument keys through JSON and leaves mirrored values for final header encoding" do
    catalog =
      Catalog.compile([
        tool("mirror", %{
          "unicode" => %{"type" => "string", "x-mcp-header" => "Unicode"},
          "crlf" => %{"type" => "string", "x-mcp-header" => "Crlf"},
          "sentinel" => %{"type" => "string", "x-mcp-header" => "Sentinel"},
          "enabled" => %{"type" => "boolean", "x-mcp-header" => "Enabled"},
          "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"}
        })
      ])

    sentinel = "=?base64?YWJj?="

    arguments = %{
      unicode: "\u5317\u4eac",
      crlf: "line\r\nbreak",
      sentinel: sentinel,
      enabled: false,
      limit: 42
    }

    assert {:ok, projected} = Catalog.parameter_headers(catalog, "mirror", arguments)

    assert projected == %{
             "Mcp-Param-Crlf" => "line\r\nbreak",
             "Mcp-Param-Enabled" => false,
             "Mcp-Param-Limit" => 42,
             "Mcp-Param-Sentinel" => sentinel,
             "Mcp-Param-Unicode" => "\u5317\u4eac"
           }

    assert {:ok, headers} = build_final_headers("mirror", arguments, projected)
    assert headers["mcp-param-crlf"] == mirrored_base64("line\r\nbreak")
    assert headers["mcp-param-enabled"] == "false"
    assert headers["mcp-param-limit"] == "42"
    assert headers["mcp-param-sentinel"] == mirrored_base64(sentinel)
    assert headers["mcp-param-unicode"] == mirrored_base64("\u5317\u4eac")
  end

  test "excludes each invalid annotated tool without poisoning valid tools" do
    invalid_tools = [
      tool("empty", %{"value" => %{"type" => "string", "x-mcp-header" => ""}}),
      tool("bad-token", %{"value" => %{"type" => "string", "x-mcp-header" => "Bad Header"}}),
      tool("number", %{"value" => %{"type" => "number", "x-mcp-header" => "Value"}}),
      tool("nullable", %{"value" => %{"type" => ["string", "null"], "x-mcp-header" => "Value"}}),
      tool("duplicate", %{
        "first" => %{"type" => "string", "x-mcp-header" => "Trace"},
        "second" => %{"type" => "string", "x-mcp-header" => "trace"}
      }),
      %{
        "name" => "items",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "values" => %{
              "type" => "array",
              "items" => %{"type" => "string", "x-mcp-header" => "Item"}
            }
          }
        }
      },
      %{
        "name" => "composition",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "choice" => %{
              "oneOf" => [%{"type" => "string", "x-mcp-header" => "Choice"}]
            }
          }
        }
      },
      %{
        "name" => "definition",
        "inputSchema" => %{
          "type" => "object",
          "$defs" => %{"value" => %{"type" => "string", "x-mcp-header" => "Hidden"}},
          "properties" => %{"value" => %{"$ref" => "#/$defs/value"}}
        }
      },
      %{
        "name" => "root-annotation",
        "inputSchema" => %{"type" => "object", "x-mcp-header" => "Root", "properties" => %{}}
      },
      %{
        "name" => "conditional",
        "inputSchema" => %{
          "type" => "object",
          "if" => %{
            "properties" => %{
              "value" => %{"type" => "string", "x-mcp-header" => "Conditional"}
            }
          }
        }
      }
    ]

    log =
      capture_log(fn ->
        catalog =
          Catalog.compile(
            invalid_tools ++
              [tool("safe", %{"id" => %{"type" => "integer", "x-mcp-header" => "Id"}})]
          )

        send(self(), {:compiled_catalog, catalog})
      end)

    assert_receive {:compiled_catalog, catalog}

    for {name, reason} <- [
          {"empty", "invalid_header_annotation"},
          {"bad-token", "invalid_header_annotation"},
          {"number", "non_primitive_header_annotation"},
          {"nullable", "non_primitive_header_annotation"},
          {"duplicate", "duplicate_header_annotation"},
          {"items", "unreachable_header_annotation"},
          {"composition", "unreachable_header_annotation"},
          {"definition", "unreachable_header_annotation"},
          {"root-annotation", "root_header_annotation"},
          {"conditional", "unreachable_header_annotation"}
        ] do
      assert log =~ ~s(Excluded Streamable HTTP tool name=#{inspect(name)} reason=#{reason})
    end

    refute log =~ "Bad Header"
    refute log =~ "Conditional"

    assert ["safe"] == Enum.map(Catalog.tools(catalog), & &1["name"])

    assert {:ok, %{"Mcp-Param-Id" => 7}} =
             Catalog.parameter_headers(catalog, "safe", %{"id" => 7})

    assert {:ok, %{}} = Catalog.parameter_headers(catalog, "number", %{"value" => 1.5})
  end

  test "atomically replaces the process-local catalog snapshot" do
    key = {:catalog_test, System.unique_integer([:positive])}

    first =
      Catalog.replace(key, [
        tool("weather", %{"city" => %{"type" => "string", "x-mcp-header" => "City"}})
      ])

    assert Catalog.current(key) == first

    second =
      Catalog.replace(key, [
        tool("weather", %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}})
      ])

    assert Catalog.current(key) == second
    assert fn -> Catalog.current(key) end |> Task.async() |> Task.await() == Catalog.empty()

    assert {:ok, %{"Mcp-Param-Region" => "eu"}} =
             Catalog.parameter_headers(second, "weather", %{"city" => "Paris", "region" => "eu"})

    refute Catalog.current(key) == first
    assert :ok = Catalog.cleanup(key)
    assert Catalog.current(key) == Catalog.empty()
  end

  test "stores filtered pages separately while merging only an exact cursor continuation" do
    key = {:catalog_page_test, System.unique_integer([:positive])}

    first_page = [
      tool("weather", %{"city" => %{"type" => "string", "x-mcp-header" => "City"}}),
      tool("clock", %{"zone" => %{"type" => "string", "x-mcp-header" => "Zone"}})
    ]

    assert {^first_page, first_catalog} = Catalog.put_page(key, nil, "cursor-1", first_page)
    assert Catalog.current(key) == first_catalog

    second_page = [
      tool("forecast", %{"days" => %{"type" => "integer", "x-mcp-header" => "Days"}})
    ]

    assert {^second_page, second_catalog} =
             Catalog.put_page(key, "cursor-1", "cursor-2", second_page)

    assert ["weather", "clock", "forecast"] ==
             Enum.map(Catalog.tools(second_catalog), & &1["name"])

    assert {:ok, %{"Mcp-Param-City" => "Paris"}} =
             Catalog.parameter_headers(second_catalog, "weather", %{city: "Paris"})

    assert {:ok, %{"Mcp-Param-Days" => 3}} =
             Catalog.parameter_headers(second_catalog, "forecast", %{days: 3})

    stale_page = [tool("replacement", %{"id" => %{"type" => "string", "x-mcp-header" => "Id"}})]

    assert {^stale_page, reset_catalog} =
             Catalog.put_page(key, "cursor-1", "replacement-cursor", stale_page)

    assert ["replacement"] == Enum.map(Catalog.tools(reset_catalog), & &1["name"])

    new_first_page = [tool("fresh", %{"id" => %{"type" => "string", "x-mcp-header" => "Id"}})]

    assert {^new_first_page, first_page_catalog} =
             Catalog.put_page(key, nil, nil, new_first_page)

    assert ["fresh"] == Enum.map(Catalog.tools(first_page_catalog), & &1["name"])
  end

  test "an invalid tool redefinition removes a stale projection during pagination" do
    key = {:catalog_redefinition_test, System.unique_integer([:positive])}

    valid = tool("weather", %{"city" => %{"type" => "string", "x-mcp-header" => "City"}})
    assert {page, _catalog} = Catalog.put_page(key, nil, "cursor-1", [valid])
    assert page == [valid]

    invalid = tool("weather", %{"value" => %{"type" => "number", "x-mcp-header" => "Value"}})
    forecast = tool("forecast", %{"days" => %{"type" => "integer", "x-mcp-header" => "Days"}})

    log =
      capture_log(fn ->
        assert {page, catalog} = Catalog.put_page(key, "cursor-1", nil, [invalid, forecast])
        assert page == [forecast]
        assert ["forecast"] == Enum.map(Catalog.tools(catalog), & &1["name"])
        assert {:ok, %{}} = Catalog.parameter_headers(catalog, "weather", %{city: "Paris"})

        assert {:ok, %{"Mcp-Param-Days" => 2}} =
                 Catalog.parameter_headers(catalog, "forecast", %{days: 2})
      end)

    assert log =~
             ~s(Excluded Streamable HTTP tool name="weather" reason=non_primitive_header_annotation)

    refute log =~ "Mcp-Param-Value"
  end

  test "filters the returned modern HTTP tool list and uses the identical snapshot for the next call" do
    {:ok, transport} = start_supervised({CaptureHTTP, self()})
    client = start_modern_http_client(transport)

    list_task = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:http_send, encoded, _context}
    list_request = JSON.decode!(encoded)

    tools = [
      tool("invalid", %{"value" => %{"type" => "number", "x-mcp-header" => "Value"}}),
      tool("weather", %{"city" => %{"type" => "string", "x-mcp-header" => "City"}})
    ]

    reply(client, list_request["id"], %{"resultType" => "complete", "tools" => tools})

    assert {:ok, response} = Task.await(list_task)
    assert ["weather"] == Enum.map(response.result["tools"], & &1["name"])

    call_task = Task.async(fn -> Client.call_tool(client, "weather", %{"city" => "Paris"}) end)
    assert_receive {:http_send, encoded, context}
    call_request = JSON.decode!(encoded)
    assert context.parameter_headers == %{"Mcp-Param-City" => "Paris"}

    reply(client, call_request["id"], %{"resultType" => "complete", "content" => []})
    assert {:ok, _response} = Task.await(call_task)

    second_list = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:http_send, encoded, _context}
    request = JSON.decode!(encoded)

    replacement = [
      tool("weather", %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}})
    ]

    reply(client, request["id"], %{"resultType" => "complete", "tools" => replacement})
    assert {:ok, _response} = Task.await(second_list)

    second_call =
      Task.async(fn ->
        Client.call_tool(client, "weather", %{"city" => "Paris", "region" => "eu"})
      end)

    assert_receive {:http_send, encoded, context}
    request = JSON.decode!(encoded)
    assert context.parameter_headers == %{"Mcp-Param-Region" => "eu"}
    reply(client, request["id"], %{"resultType" => "complete", "content" => []})
    assert {:ok, _response} = Task.await(second_call)
  end

  test "returns only each filtered page while retaining an exact cursor chain for later calls" do
    {:ok, transport} = start_supervised({CaptureHTTP, self()})
    client = start_modern_http_client(transport)

    first_list = Task.async(fn -> Client.list_tools(client) end)
    assert_receive {:http_send, encoded, _context}
    first_request = JSON.decode!(encoded)

    first_page = [
      tool("weather", %{"city" => %{"type" => "string", "x-mcp-header" => "City"}})
    ]

    reply(client, first_request["id"], %{
      "resultType" => "complete",
      "nextCursor" => "cursor-1",
      "tools" => first_page
    })

    assert {:ok, first_response} = Task.await(first_list)
    assert ["weather"] == Enum.map(first_response.result["tools"], & &1["name"])

    second_list = Task.async(fn -> Client.list_tools(client, cursor: "cursor-1") end)
    assert_receive {:http_send, encoded, _context}
    second_request = JSON.decode!(encoded)
    assert second_request["params"]["cursor"] == "cursor-1"

    second_page = [
      tool("invalid", %{"value" => %{"type" => "number", "x-mcp-header" => "Value"}}),
      tool("forecast", %{"days" => %{"type" => "integer", "x-mcp-header" => "Days"}})
    ]

    reply(client, second_request["id"], %{
      "resultType" => "complete",
      "tools" => second_page
    })

    assert {:ok, second_response} = Task.await(second_list)
    assert ["forecast"] == Enum.map(second_response.result["tools"], & &1["name"])

    weather_call = Task.async(fn -> Client.call_tool(client, "weather", %{city: "Paris"}) end)
    assert_receive {:http_send, encoded, context}
    weather_request = JSON.decode!(encoded)
    assert context.parameter_headers == %{"Mcp-Param-City" => "Paris"}

    reply(client, weather_request["id"], %{"resultType" => "complete", "content" => []})
    assert {:ok, _response} = Task.await(weather_call)
  end

  defp start_modern_http_client(transport) do
    client =
      start_supervised!(%{
        id: {Client, System.unique_integer([:positive])},
        start:
          {Client, :start_link_server,
           [
             [
               name: nil,
               transport: [layer: StreamableHTTP, name: transport],
               client_info: %{"name" => "CatalogTest", "version" => "1.0.0"},
               capabilities: %{},
               protocol_version: "2026-07-28",
               timeout: 1_000
             ]
           ]},
        restart: :temporary
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          negotiation_status: :ready,
          negotiated_version: "2026-07-28",
          server_capabilities: %{"tools" => %{}}
      }
    end)

    client
  end

  defp reply(client, id, result) do
    GenServer.cast(
      client,
      {:response, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    )
  end

  defp tool(name, properties) do
    %{
      "name" => name,
      "inputSchema" => %{"type" => "object", "properties" => properties}
    }
  end

  defp build_final_headers(tool_name, arguments, parameter_headers) do
    params = %{
      "name" => tool_name,
      "arguments" => arguments,
      "_meta" => %{
        @protocol_version_key => "2026-07-28",
        @client_capabilities_key => %{}
      }
    }

    context =
      RequestContext.new(
        "tools/call",
        params,
        %{protocol_version: "2026-07-28", era: :modern},
        parameter_headers: parameter_headers
      )

    encoded =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "catalog-header-test",
        "method" => "tools/call",
        "params" => params
      })

    Headers.build(%{}, encoded, context)
  end

  defp mirrored_base64(value), do: "=?base64?" <> Base.encode64(value) <> "?="
end
