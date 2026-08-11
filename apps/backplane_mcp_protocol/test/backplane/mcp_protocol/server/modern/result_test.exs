defmodule Backplane.McpProtocol.Server.Modern.ResultTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Modern.RequestContext
  alias Backplane.McpProtocol.Server.Modern.Result

  defmodule TestServer do
    @moduledoc false
    def server_info, do: %{"name" => "modern-test", "version" => "1.0.0"}
  end

  defmodule MalformedInfoServer do
    @moduledoc false
    def server_info, do: %{"name" => "missing-version"}
  end

  test "defaults resultType and installs authoritative server metadata" do
    context = request_context("tools/call")
    frame = Frame.new()

    callback_result = %{
      "content" => [],
      "_meta" => %{
        "com.example/trace" => "trace-1",
        "io.modelcontextprotocol/serverInfo" => %{"name" => "spoofed", "version" => "0"}
      }
    }

    assert {:ok, result} =
             Result.normalize("tools/call", {:reply, callback_result, frame}, context, TestServer)

    assert result["resultType"] == "complete"
    assert result["_meta"]["com.example/trace"] == "trace-1"

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "modern-test",
             "version" => "1.0.0"
           }
  end

  test "normalizes atom metadata keys before replacing reserved serverInfo" do
    spoofed_key = :"io.modelcontextprotocol/serverInfo"
    trace_key = :"com.example/trace"

    callback_result = %{
      "_meta" => %{
        spoofed_key => %{"name" => "spoofed", "version" => "0"},
        trace_key => "trace-atom"
      }
    }

    assert {:ok, result} =
             Result.normalize(
               "tools/call",
               {:reply, callback_result, Frame.new()},
               request_context("tools/call"),
               TestServer
             )

    refute Map.has_key?(result["_meta"], spoofed_key)
    refute Map.has_key?(result["_meta"], trace_key)
    assert result["_meta"]["com.example/trace"] == "trace-atom"
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "modern-test"
  end

  test "accepts a precomputed server-info snapshot from the isolated executor" do
    snapshot = %{server_info: %{name: "snapshot-server", version: "2.0.0"}}

    assert {:ok, result} =
             Result.normalize(
               "tools/call",
               {:reply, %{}, Frame.new()},
               request_context("tools/call"),
               snapshot
             )

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "snapshot-server",
             "version" => "2.0.0"
           }
  end

  test "validates and normalizes known optional serverInfo fields" do
    server_info = %{
      name: "snapshot-server",
      version: "2.0.0",
      title: "Snapshot Server",
      description: "A test implementation",
      websiteUrl: "https://example.test/server",
      icons: [
        %{
          src: "https://example.test/server.svg",
          mimeType: "image/svg+xml",
          sizes: ["any"],
          theme: "light",
          "com.example/density": 2
        }
      ],
      "com.example/channel": "preview"
    }

    assert {:ok, result} =
             Result.normalize(
               "tools/call",
               {:reply, %{}, Frame.new()},
               request_context("tools/call"),
               %{server_info: server_info}
             )

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "snapshot-server",
             "version" => "2.0.0",
             "title" => "Snapshot Server",
             "description" => "A test implementation",
             "websiteUrl" => "https://example.test/server",
             "icons" => [
               %{
                 "src" => "https://example.test/server.svg",
                 "mimeType" => "image/svg+xml",
                 "sizes" => ["any"],
                 "theme" => "light",
                 "com.example/density" => 2
               }
             ],
             "com.example/channel" => "preview"
           }

    malformed = [
      Map.put(server_info, :title, 7),
      Map.put(server_info, :description, 7),
      Map.put(server_info, :websiteUrl, "relative/path"),
      Map.put(server_info, :icons, %{}),
      Map.put(server_info, :icons, [%{src: "relative/icon.svg"}]),
      Map.put(server_info, :icons, [%{src: "https://example.test/icon.svg", mimeType: 7}]),
      Map.put(server_info, :icons, [%{src: "https://example.test/icon.svg", sizes: [16]}]),
      Map.put(server_info, :icons, [%{src: "https://example.test/icon.svg", theme: "system"}])
    ]

    for invalid_info <- malformed do
      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, %{}, Frame.new()},
                 request_context("tools/call"),
                 %{server_info: invalid_info}
               )
    end
  end

  test "remaps legacy resource-not-found errors to modern invalid params" do
    context = request_context("resources/read")
    frame = Frame.new()
    legacy_error = Error.resource(:not_found, %{uri: "file:///missing"})

    assert {:error, %Error{code: -32_602, reason: :invalid_params, data: %{uri: "file:///missing"}}} =
             Result.normalize(
               "resources/read",
               {:error, legacy_error, frame},
               context,
               TestServer
             )
  end

  test "adds conservative defaults to cacheable results and preserves valid explicit hints" do
    context = request_context("tools/list")
    frame = Frame.new()

    assert {:ok, defaulted} =
             Result.normalize("tools/list", {:reply, %{"tools" => []}, frame}, context, TestServer)

    assert defaulted["ttlMs"] == 0
    assert defaulted["cacheScope"] == "private"

    explicit = %{"tools" => [], "ttlMs" => 30_000, "cacheScope" => "public"}

    assert {:ok, preserved} =
             Result.normalize("tools/list", {:reply, explicit, frame}, context, TestServer)

    assert preserved["ttlMs"] == 30_000
    assert preserved["cacheScope"] == "public"
  end

  test "forces retry-derived cacheable results immediately stale and private" do
    frame = Frame.new()
    explicit = %{"resources" => [], "ttlMs" => 30_000, "cacheScope" => "public"}

    for params <- [%{"inputResponses" => %{}}, %{"requestState" => "opaque"}] do
      context = request_context("resources/list", params)

      assert {:ok, result} =
               Result.normalize("resources/list", {:reply, explicit, frame}, context, TestServer)

      assert result["ttlMs"] == 0
      assert result["cacheScope"] == "private"
    end
  end

  test "forces an initial input_required cacheable result immediately stale and private" do
    result = %{
      "resultType" => "input_required",
      "inputRequests" => %{},
      "ttlMs" => 30_000,
      "cacheScope" => "public"
    }

    assert {:ok, normalized} =
             Result.normalize(
               "resources/read",
               {:reply, result, Frame.new()},
               request_context("resources/read"),
               TestServer
             )

    assert normalized["ttlMs"] == 0
    assert normalized["cacheScope"] == "private"
  end

  test "sanitizes invalid cache hints on cacheable results" do
    context = request_context("tools/list")
    frame = Frame.new()

    malformed = [
      %{"tools" => [], "ttlMs" => -1},
      %{"tools" => [], "ttlMs" => 1.5},
      %{"tools" => [], "cacheScope" => "shared"},
      %{"tools" => [], "cacheScope" => nil}
    ]

    for result <- malformed do
      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize("tools/list", {:reply, result, frame}, context, TestServer)
    end
  end

  test "accepts input_required only on the three MRTR result methods" do
    frame = Frame.new()
    input_required = %{"resultType" => "input_required", "inputRequests" => %{}}

    for method <- ["tools/call", "prompts/get", "resources/read"] do
      assert {:ok, %{"resultType" => "input_required", "inputRequests" => %{}}} =
               Result.normalize(
                 method,
                 {:reply, input_required, frame},
                 request_context(method),
                 TestServer
               )
    end

    assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
             Result.normalize(
               "tools/list",
               {:reply, input_required, frame},
               request_context("tools/list"),
               TestServer
             )
  end

  test "accepts requestState-only input_required results" do
    result = %{"resultType" => "input_required", "requestState" => "opaque-state"}

    assert {:ok, normalized} =
             Result.normalize(
               "prompts/get",
               {:reply, result, Frame.new()},
               request_context("prompts/get"),
               TestServer
             )

    assert normalized["requestState"] == "opaque-state"
  end

  test "sanitizes malformed input_required field shapes" do
    context = request_context("tools/call")
    frame = Frame.new()

    malformed = [
      %{"resultType" => "input_required"},
      %{"resultType" => "input_required", "inputRequests" => nil},
      %{"resultType" => "input_required", "inputRequests" => []},
      %{"resultType" => "input_required", "requestState" => nil},
      %{"resultType" => "input_required", "requestState" => 123}
    ]

    for result <- malformed do
      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize("tools/call", {:reply, result, frame}, context, TestServer)
    end
  end

  test "aggregates all missing capabilities required by embedded input requests" do
    input_requests = %{
      "roots" => %{"method" => "roots/list"},
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 64, "tools" => []}
      },
      "form" => %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Choose",
          "requestedSchema" => %{"type" => "object", "properties" => %{}}
        }
      },
      "url" => %{
        "method" => "elicitation/create",
        "params" => %{"mode" => "url", "message" => "Authorize", "url" => "https://example.test"}
      }
    }

    result = %{"resultType" => "input_required", "inputRequests" => input_requests}

    assert {:error,
            %Error{
              code: -32_021,
              reason: :missing_client_capability,
              data: %{
                "requiredCapabilities" => %{
                  "roots" => %{},
                  "sampling" => %{"tools" => %{}},
                  "elicitation" => %{"form" => %{}, "url" => %{}}
                }
              }
            }} =
             Result.normalize(
               "tools/call",
               {:reply, result, Frame.new()},
               request_context("tools/call"),
               TestServer
             )
  end

  test "rejects JSON-RPC envelopes embedded where bare input requests are required" do
    context = request_context("tools/call", %{}, %{"roots" => %{}})

    for wrapper_field <- [%{"id" => 7}, %{"jsonrpc" => "2.0"}] do
      embedded = Map.merge(%{"method" => "roots/list"}, wrapper_field)
      result = %{"resultType" => "input_required", "inputRequests" => %{"roots" => embedded}}

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, result, Frame.new()},
                 context,
                 TestServer
               )
    end
  end

  test "roots/list accepts only optional metadata params" do
    context = request_context("tools/call", %{}, %{"roots" => %{}})

    accepted = %{"method" => "roots/list", "params" => %{"_meta" => %{"com.example/x" => true}}}

    assert {:ok, _result} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("roots", accepted), Frame.new()},
               context,
               TestServer
             )

    rejected = %{"method" => "roots/list", "params" => %{"cursor" => "unexpected"}}

    assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("roots", rejected), Frame.new()},
               context,
               TestServer
             )
  end

  test "sampling/createMessage accepts numeric maxTokens from the frozen TypeScript schema" do
    context = request_context("tools/call", %{}, %{"sampling" => %{}})

    request = %{
      "method" => "sampling/createMessage",
      "params" => %{"messages" => [], "maxTokens" => 64.5}
    }

    assert {:ok, _result} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("sample", request), Frame.new()},
               context,
               TestServer
             )
  end

  test "sampling/createMessage validates every sampling content block shape" do
    context = request_context("tools/call", %{}, %{"sampling" => %{}})

    valid_content = [
      %{
        "type" => "text",
        "text" => "hello",
        "annotations" => %{"audience" => ["user"], "priority" => 0.5},
        "_meta" => %{"com.example/source" => "test"}
      },
      %{"type" => "image", "data" => "aW1hZ2U=", "mimeType" => "image/png"},
      %{"type" => "audio", "data" => "YXVkaW8=", "mimeType" => "audio/wav"},
      %{
        "type" => "tool_use",
        "id" => "call-1",
        "name" => "lookup",
        "input" => %{},
        "_meta" => %{}
      },
      %{
        "type" => "tool_result",
        "toolUseId" => "call-1",
        "content" => [
          %{"type" => "text", "text" => "done"},
          %{
            "type" => "resource_link",
            "name" => "report",
            "uri" => "file:///tmp/report.txt",
            "title" => "Report",
            "description" => "Generated report",
            "mimeType" => "text/plain",
            "icons" => [%{"src" => "https://example.test/report.svg", "theme" => "light"}],
            "size" => 12.5,
            "annotations" => %{"lastModified" => "2026-07-28T00:00:00Z"},
            "_meta" => %{}
          },
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "file:///tmp/report.txt",
              "mimeType" => "text/plain",
              "text" => "report",
              "_meta" => %{}
            }
          },
          %{
            "type" => "resource",
            "resource" => %{"uri" => "file:///tmp/report.bin", "blob" => "YmxvYg=="}
          }
        ],
        "isError" => false,
        "_meta" => %{}
      }
    ]

    for content <- valid_content ++ [valid_content] do
      request = sampling_request(%{"messages" => [%{"role" => "assistant", "content" => content}]})

      assert {:ok, _result} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end

    malformed_content = [
      %{"type" => "unknown"},
      %{"type" => "text"},
      %{"type" => "text", "text" => 1},
      %{"type" => "image", "data" => "aW1hZ2U="},
      %{"type" => "audio", "data" => 1, "mimeType" => "audio/wav"},
      %{"type" => "tool_use", "id" => "call-1", "name" => "lookup", "input" => []},
      %{"type" => "text", "text" => "hello", "annotations" => %{"priority" => 1.1}},
      [[%{"type" => "text", "text" => "nested arrays are invalid"}]],
      %{"type" => "tool_result", "toolUseId" => "call-1", "content" => [%{"type" => "tool_use"}]},
      %{
        "type" => "tool_result",
        "toolUseId" => "call-1",
        "content" => [%{"type" => "resource_link", "name" => "bad", "uri" => "relative"}]
      },
      %{
        "type" => "tool_result",
        "toolUseId" => "call-1",
        "content" => [
          %{
            "type" => "resource_link",
            "name" => "non-number",
            "uri" => "file:///tmp/non-number",
            "size" => "12.5"
          }
        ]
      },
      %{
        "type" => "tool_result",
        "toolUseId" => "call-1",
        "content" => [
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "file:///tmp/both",
              "text" => "text",
              "blob" => "YmxvYg=="
            }
          }
        ]
      },
      %{"type" => "tool_result", "toolUseId" => "call-1", "content" => [], "isError" => "no"}
    ]

    for content <- malformed_content do
      request = sampling_request(%{"messages" => [%{"role" => "user", "content" => content}]})

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end
  end

  test "sampling/createMessage validates known model preference fields" do
    context = request_context("tools/call", %{}, %{"sampling" => %{}})

    valid_preferences = [
      %{},
      %{
        "hints" => [%{}, %{"name" => "claude", "com.example/tier" => "fast"}],
        "costPriority" => 0,
        "speedPriority" => 0.5,
        "intelligencePriority" => 1,
        "com.example/selectionPolicy" => "balanced"
      }
    ]

    for model_preferences <- valid_preferences do
      request = sampling_request(%{"messages" => [], "modelPreferences" => model_preferences})

      assert {:ok, _result} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end

    malformed_preferences = [
      %{"hints" => %{}},
      %{"hints" => [nil]},
      %{"hints" => [%{"name" => 7}]},
      %{"costPriority" => -0.1},
      %{"speedPriority" => 1.1},
      %{"intelligencePriority" => "high"}
    ]

    for model_preferences <- malformed_preferences do
      request = sampling_request(%{"messages" => [], "modelPreferences" => model_preferences})

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end
  end

  test "sampling/createMessage validates the complete known Tool shape" do
    context = request_context("tools/call", %{}, %{"sampling" => %{"tools" => %{}}})

    tool = %{
      "name" => "lookup",
      "title" => "Lookup",
      "description" => "Looks up a value",
      "icons" => [
        %{
          "src" => "https://example.test/lookup.svg",
          "mimeType" => "image/svg+xml",
          "sizes" => ["any"],
          "theme" => "dark",
          "com.example/density" => 2
        }
      ],
      "inputSchema" => %{
        "type" => "object",
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "properties" => %{}
      },
      "outputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => %{
        "title" => "Safe lookup",
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false,
        "com.example/policy" => "audited"
      },
      "_meta" => %{"com.example/version" => 1},
      "com.example/category" => "search"
    }

    for tool_choice <- [%{}, %{"mode" => "auto"}, %{"mode" => "required"}, %{"mode" => "none"}] do
      request =
        sampling_request(%{"messages" => [], "tools" => [tool], "toolChoice" => tool_choice})

      assert {:ok, _result} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end

    malformed_tools = [
      %{"inputSchema" => %{"type" => "object"}},
      %{"name" => 7, "inputSchema" => %{"type" => "object"}},
      %{"name" => "lookup", "inputSchema" => %{}},
      %{"name" => "lookup", "inputSchema" => %{"type" => "array"}},
      %{"name" => "lookup", "inputSchema" => %{"type" => "object", "$schema" => 7}},
      Map.put(tool, "title", 7),
      Map.put(tool, "description", 7),
      Map.put(tool, "icons", %{}),
      Map.put(tool, "icons", [%{"src" => "relative/icon.svg"}]),
      Map.put(tool, "icons", [%{"src" => "https://example.test/icon.svg", "sizes" => [16]}]),
      Map.put(tool, "icons", [%{"src" => "https://example.test/icon.svg", "theme" => "system"}]),
      Map.put(tool, "outputSchema", []),
      Map.put(tool, "outputSchema", %{"$schema" => 7}),
      Map.put(tool, "annotations", %{"readOnlyHint" => "yes"}),
      Map.put(tool, "_meta", [])
    ]

    for malformed_tool <- malformed_tools do
      request = sampling_request(%{"messages" => [], "tools" => [malformed_tool]})

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end
  end

  test "sanitizes malformed sampling request shapes" do
    context = request_context("tools/call", %{}, %{"sampling" => %{"tools" => %{}}})

    malformed_params = [
      %{"messages" => []},
      %{"maxTokens" => 64},
      %{"messages" => [], "maxTokens" => "64"},
      %{"messages" => [nil], "maxTokens" => 64},
      %{"messages" => [], "maxTokens" => 64, "tools" => %{}},
      %{"messages" => [], "maxTokens" => 64, "tools" => [nil]},
      %{"messages" => [], "maxTokens" => 64, "toolChoice" => %{"mode" => "sometimes"}}
    ]

    for params <- malformed_params do
      request = %{"method" => "sampling/createMessage", "params" => params}

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, input_required("sample", request), Frame.new()},
                 context,
                 TestServer
               )
    end
  end

  test "URL elicitation requires a valid absolute URI" do
    context = request_context("tools/call", %{}, %{"elicitation" => %{"url" => %{}}})

    valid = %{
      "method" => "elicitation/create",
      "params" => %{"mode" => "url", "message" => "Authorize", "url" => "https://example.test/start"}
    }

    assert {:ok, _result} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("url", valid), Frame.new()},
               context,
               TestServer
             )

    invalid = put_in(valid, ["params", "url"], "relative/path")

    assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("url", invalid), Frame.new()},
               context,
               TestServer
             )
  end

  test "bare elicitation capability satisfies form mode and malformed form schemas are sanitized" do
    context = request_context("tools/call", %{}, %{"elicitation" => %{}})

    valid = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Choose a label",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}},
          "required" => ["label"]
        }
      }
    }

    assert {:ok, _result} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("form", valid), Frame.new()},
               context,
               TestServer
             )

    invalid =
      put_in(valid, ["params", "requestedSchema", "properties", "label"], %{"type" => "object"})

    assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
             Result.normalize(
               "tools/call",
               {:reply, input_required("form", invalid), Frame.new()},
               context,
               TestServer
             )
  end

  test "reports only the missing nested capability subset for the current request" do
    input_requests = %{
      "roots" => %{"method" => "roots/list"},
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 32, "toolChoice" => %{}}
      },
      "form" => %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Choose",
          "requestedSchema" => %{"type" => "object", "properties" => %{}}
        }
      },
      "url" => %{
        "method" => "elicitation/create",
        "params" => %{"mode" => "url", "message" => "Authorize", "url" => "https://example.test"}
      }
    }

    capabilities = %{"roots" => %{}, "sampling" => %{}, "elicitation" => %{}}
    context = request_context("tools/call", %{}, capabilities)
    result = %{"resultType" => "input_required", "inputRequests" => input_requests}

    assert {:error,
            %Error{
              code: -32_021,
              data: %{
                "requiredCapabilities" => %{
                  "sampling" => %{"tools" => %{}},
                  "elicitation" => %{"url" => %{}}
                }
              }
            }} =
             Result.normalize("tools/call", {:reply, result, Frame.new()}, context, TestServer)
  end

  test "rejects unknown embedded methods and missing required params" do
    malformed = [
      %{"method" => "unknown/request", "params" => %{}},
      %{"method" => "sampling/createMessage"},
      %{"method" => "elicitation/create"},
      %{"method" => "elicitation/create", "params" => %{"mode" => "url"}}
    ]

    for {request, index} <- Enum.with_index(malformed) do
      result = input_required("bad-#{index}", request)

      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize(
                 "tools/call",
                 {:reply, result, Frame.new()},
                 request_context("tools/call"),
                 TestServer
               )
    end
  end

  test "preserves extension result types and sanitizes malformed callback output" do
    context = request_context("tools/call")
    frame = Frame.new()

    assert {:ok, %{"resultType" => "com.example/deferred"}} =
             Result.normalize(
               "tools/call",
               {:reply, %{"resultType" => "com.example/deferred"}, frame},
               context,
               TestServer
             )

    malformed = [
      {{:reply, %{"resultType" => 7}, frame}, TestServer},
      {{:reply, %{"_meta" => nil}, frame}, TestServer},
      {{:reply, :not_a_map, frame}, TestServer},
      {{:reply, %{"content" => self()}, frame}, TestServer},
      {{:noreply, frame}, TestServer},
      {{:reply, %{}, :not_a_frame}, TestServer},
      {{:reply, %{}, frame}, MalformedInfoServer}
    ]

    for {outcome, server} <- malformed do
      assert {:error, %Error{code: -32_603, reason: :internal_error, data: %{}}} =
               Result.normalize("tools/call", outcome, context, server)
    end
  end

  test "preserves explicit application errors that are not legacy resource misses" do
    context = request_context("tools/call")
    frame = Frame.new()
    application_error = Error.execution("denied", %{reason: "policy"})

    assert {:error, ^application_error} =
             Result.normalize(
               "tools/call",
               {:error, application_error, frame},
               context,
               TestServer
             )
  end

  defp request_context(method, params \\ %{}, client_capabilities \\ %{}) do
    {:ok, profile} = Registry.profile("2026-07-28")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => client_capabilities
        })
    }

    {:ok, context} = RequestContext.build(profile, request, %{transport: :stdio})
    context
  end

  defp input_required(id, request) do
    %{"resultType" => "input_required", "inputRequests" => %{id => request}}
  end

  defp sampling_request(params) do
    %{
      "method" => "sampling/createMessage",
      "params" => Map.put_new(params, "maxTokens", 64)
    }
  end
end
