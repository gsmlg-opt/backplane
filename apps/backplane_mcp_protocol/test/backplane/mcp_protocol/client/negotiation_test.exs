defmodule Backplane.McpProtocol.Client.NegotiationTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Client.Negotiation
  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol
  alias Backplane.McpProtocol.Transport.STDIO
  alias Backplane.McpProtocol.Transport.StreamableHTTP

  @modern_version "2026-07-28"
  @version_key "io.modelcontextprotocol/protocolVersion"
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  describe "begin/1" do
    test "auto probes the preferred modern version with namespaced request metadata" do
      state = state(:auto, STDIO)

      assert {:send, operation, state} = Negotiation.begin(state)
      assert operation.method == "server/discover"

      assert %{
               "_meta" => %{
                 @version_key => @modern_version,
                 @capabilities_key => %{"roots" => %{}},
                 @client_info_key => %{"name" => "TestClient", "version" => "1.0.0"}
               }
             } = operation.params

      assert state.protocol_version == @modern_version
      assert state.negotiation_status == :discovering
      assert state.era == :modern
    end

    test "omits invalid modern client info" do
      state = %{state(:auto, STDIO) | client_info: %{"name" => "missing-version"}}

      assert {:send, operation, _state} = Negotiation.begin(state)
      refute Map.has_key?(operation.params["_meta"], @client_info_key)
    end

    test "omits modern client info with a non-string website URL without raising" do
      state = %{
        state(:auto, STDIO)
        | client_info: %{
            "name" => "TestClient",
            "version" => "1.0.0",
            "websiteUrl" => 42
          }
      }

      assert {:send, operation, _state} = Negotiation.begin(state)
      refute Map.has_key?(operation.params["_meta"], @client_info_key)
    end

    test "a pinned legacy version initializes directly" do
      state = state("2025-06-18", STDIO)

      assert {:send, operation, state} = Negotiation.begin(state)
      assert operation.method == "initialize"

      assert operation.params == %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"roots" => %{}},
               "clientInfo" => %{"name" => "TestClient", "version" => "1.0.0"}
             }

      assert state.negotiation_status == :initializing
      assert state.era == :legacy
    end

    test "a pinned modern version probes exactly that version" do
      state = state(@modern_version, STDIO)

      assert {:send, operation, state} = Negotiation.begin(state)
      assert operation.method == "server/discover"
      assert operation.params["_meta"][@version_key] == @modern_version
      assert state.protocol_pinned?
    end
  end

  describe "handle_result/3" do
    test "a discovery result records modern protocol context and nested server identity" do
      initial = state(:auto, STDIO)
      {:send, operation, discovering} = Negotiation.begin(initial)
      request = request(operation)

      result = %{
        "resultType" => "complete",
        "supportedVersions" => [@modern_version],
        "capabilities" => %{"tools" => %{}},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "serverInfo" => %{"name" => "must-not-be-used", "version" => "0"},
        "_meta" => %{
          @server_info_key => %{"name" => "ModernServer", "version" => "2.0.0"}
        }
      }

      assert {:ready, ready} = Negotiation.handle_result(discovering, request, result)
      assert ready.negotiation_status == :ready
      assert ready.era == :modern
      assert ready.protocol_version == @modern_version
      assert ready.negotiated_version == @modern_version
      assert ready.peer_versions == [@modern_version]
      assert ready.server_capabilities == %{"tools" => %{}}
      assert ready.server_info == %{"name" => "ModernServer", "version" => "2.0.0"}
      assert ready.discovery == result
      assert ready.negotiation_error == nil
    end

    test "a discovery result retries the highest mutually supported modern version" do
      state = state(:auto, STDIO)

      operation = discover_operation("2099-01-01")
      request = request(operation)

      result = %{
        "resultType" => "complete",
        "supportedVersions" => ["2098-01-01", @modern_version],
        "capabilities" => %{},
        "ttlMs" => 0,
        "cacheScope" => "private"
      }

      assert {:send, retry, retrying} = Negotiation.handle_result(state, request, result)
      assert retry.method == "server/discover"
      assert retry.params["_meta"][@version_key] == @modern_version
      assert retrying.protocol_version == @modern_version
      assert retrying.peer_versions == ["2098-01-01", @modern_version]
      assert retrying.negotiation_status == :discovering
    end

    test "a discovery result with no mutual modern version fails" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      assert {:error, %Error{reason: :unsupported_protocol_version} = error, failed} =
               Negotiation.handle_result(state, request, %{
                 "resultType" => "complete",
                 "supportedVersions" => ["2099-01-01"],
                 "capabilities" => %{},
                 "ttlMs" => 0,
                 "cacheScope" => "private"
               })

      assert failed.negotiation_status == :failed
      assert failed.negotiation_error == error
    end

    test "a pinned modern version refuses a different successful version" do
      state = state(@modern_version, STDIO)
      request = request(discover_operation(@modern_version))

      assert {:error, %Error{reason: :unsupported_protocol_version}, failed} =
               Negotiation.handle_result(state, request, %{
                 "resultType" => "complete",
                 "supportedVersions" => ["2099-01-01"],
                 "capabilities" => %{},
                 "ttlMs" => 0,
                 "cacheScope" => "private"
               })

      assert failed.protocol_preference == @modern_version
      assert failed.negotiation_status == :failed
    end

    for result_type <- [nil, "stream"] do
      test "rejects discovery resultType #{inspect(result_type)}", %{} do
        state = state(:auto, STDIO)
        request = request(discover_operation(@modern_version))

        result = %{
          "resultType" => unquote(result_type),
          "supportedVersions" => [@modern_version],
          "capabilities" => %{},
          "ttlMs" => 0,
          "cacheScope" => "private"
        }

        assert {:error, %Error{reason: :invalid_params}, failed} =
                 Negotiation.handle_result(state, request, result)

        assert failed.negotiation_status == :failed
      end
    end

    test "requires valid frozen discovery cache fields" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      valid = valid_discovery_result()

      invalid_results = [
        Map.delete(valid, "ttlMs"),
        Map.put(valid, "ttlMs", -1),
        Map.put(valid, "ttlMs", -0.5),
        Map.put(valid, "ttlMs", "1.5"),
        Map.delete(valid, "cacheScope"),
        Map.put(valid, "cacheScope", "shared")
      ]

      for result <- invalid_results do
        assert {:error, %Error{reason: :invalid_params}, failed} =
                 Negotiation.handle_result(state, request, result)

        assert failed.negotiation_status == :failed
      end
    end

    test "rejects a fractional frozen discovery ttlMs" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      result = Map.put(valid_discovery_result(), "ttlMs", 1.5)

      assert {:error, %Error{reason: :invalid_params}, failed} =
               Negotiation.handle_result(state, request, result)

      assert failed.negotiation_status == :failed
    end

    test "requires valid frozen discovery versions and capabilities" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      valid = valid_discovery_result()

      invalid_results = [
        Map.delete(valid, "supportedVersions"),
        Map.put(valid, "supportedVersions", "2026-07-28"),
        Map.put(valid, "supportedVersions", [@modern_version, 42]),
        Map.delete(valid, "capabilities"),
        Map.put(valid, "capabilities", [])
      ]

      for result <- invalid_results do
        assert {:error, %Error{reason: :invalid_params}, failed} =
                 Negotiation.handle_result(state, request, result)

        assert failed.negotiation_status == :failed
      end
    end

    test "accepts the full frozen ServerCapabilities shape and preserves open fields" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      capabilities = %{
        "logging" => %{"vendor" => [1, 1.5, true, nil, %{"nested" => "value"}]},
        "completions" => %{},
        "prompts" => %{"listChanged" => true, "vendor" => "preserved"},
        "resources" => %{
          "subscribe" => true,
          "listChanged" => false,
          "vendor" => %{"mode" => "live"}
        },
        "tools" => %{"listChanged" => false, "vendor" => ["preserved"]},
        "experimental" => %{"com.example/feature" => %{"enabled" => true}},
        "extensions" => %{"io.modelcontextprotocol/tasks" => %{"version" => 1}},
        "com.example/custom" => true
      }

      result = Map.put(valid_discovery_result(), "capabilities", capabilities)

      assert {:ready, ready} = Negotiation.handle_result(state, request, result)
      assert ready.server_capabilities == capabilities
    end

    test "rejects malformed known frozen ServerCapabilities declarations" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      valid = valid_discovery_result()

      invalid_capabilities = [
        %{tools: %{}},
        %{"logging" => []},
        %{"logging" => %{"vendor" => self()}},
        %{"completions" => []},
        %{"prompts" => []},
        %{"prompts" => %{"listChanged" => "yes"}},
        %{"prompts" => %{"vendor" => self()}},
        %{"resources" => []},
        %{"resources" => %{"subscribe" => "yes"}},
        %{"resources" => %{"listChanged" => 1}},
        %{"tools" => []},
        %{"tools" => %{"listChanged" => nil}},
        %{"experimental" => []},
        %{"experimental" => %{"com.example/feature" => true}},
        %{"experimental" => %{"com.example/feature" => %{nested: true}}},
        %{"extensions" => []},
        %{"extensions" => %{"io.modelcontextprotocol/tasks" => true}},
        %{"extensions" => %{"tasks" => %{}}},
        %{"extensions" => %{"1example.invalid/tasks" => %{}}},
        %{"extensions" => %{"com.example/task-" => %{}}},
        %{"extensions" => %{"com.example/tasks" => %{nested: true}}}
      ]

      for capabilities <- invalid_capabilities do
        result = Map.put(valid, "capabilities", capabilities)

        assert {:error, %Error{reason: :invalid_params}, failed} =
                 Negotiation.handle_result(state, request, result)

        assert failed.negotiation_status == :failed
      end
    end

    test "validates optional frozen discovery fields and nested server identity" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      valid = valid_discovery_result()

      invalid_results = [
        Map.put(valid, "instructions", []),
        Map.put(valid, "_meta", []),
        Map.put(valid, "_meta", %{@server_info_key => %{}}),
        Map.put(valid, "_meta", %{
          @server_info_key => %{
            "name" => "ModernServer",
            "version" => "2.0.0",
            "websiteUrl" => "/relative"
          }
        }),
        Map.put(valid, "_meta", %{
          @server_info_key => %{
            "name" => "ModernServer",
            "version" => "2.0.0",
            "icons" => [%{"src" => "not-an-absolute-uri"}]
          }
        })
      ]

      for result <- invalid_results do
        assert {:error, %Error{reason: :invalid_params}, failed} =
                 Negotiation.handle_result(state, request, result)

        assert failed.negotiation_status == :failed
      end
    end

    test "accepts absent optional fields and leaves modern server info nil" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      assert {:ready, ready} =
               Negotiation.handle_result(state, request, valid_discovery_result())

      assert ready.server_info == nil
    end

    test "accepts string instructions and a fully valid nested server identity" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      server_info = %{
        "name" => "ModernServer",
        "version" => "2.0.0",
        "title" => "Modern Server",
        "description" => "A modern MCP server",
        "websiteUrl" => "https://example.com/server",
        "icons" => [
          %{
            "src" => "https://example.com/icon.svg",
            "mimeType" => "image/svg+xml",
            "sizes" => ["any"],
            "theme" => "dark"
          }
        ]
      }

      result =
        valid_discovery_result()
        |> Map.put("instructions", "Read the server instructions")
        |> Map.put("_meta", %{@server_info_key => server_info})

      assert {:ready, ready} = Negotiation.handle_result(state, request, result)
      assert ready.server_info == server_info
    end

    test "legacy initialization accepts the returned legacy version as authoritative" do
      state = state("2025-06-18", STDIO)
      {:send, operation, initializing} = Negotiation.begin(state)

      result = %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{"resources" => %{}},
        "serverInfo" => %{"name" => "LegacyServer", "version" => "1.0.0"}
      }

      assert {:ready, ready} = Negotiation.handle_result(initializing, request(operation), result)
      assert ready.negotiation_status == :ready
      assert ready.era == :legacy
      assert ready.protocol_version == "2025-03-26"
      assert ready.negotiated_version == "2025-03-26"
      assert ready.server_capabilities == %{"resources" => %{}}
      assert ready.server_info == %{"name" => "LegacyServer", "version" => "1.0.0"}
    end

    test "ordinary request methods are rejected as negotiation transitions" do
      state = state(:auto, STDIO)
      request = request(%{discover_operation(@modern_version) | method: "tools/list"})

      assert {:error, %Error{reason: :internal_error}, failed} =
               Negotiation.handle_result(state, request, %{"serverInfo" => %{}})

      assert failed.negotiation_status == :failed
    end
  end

  describe "handle_error/3" do
    test "auto retries a mutually supported modern version from -32022" do
      state = state(:auto, STDIO)
      request = request(discover_operation("2099-01-01"))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => "2099-01-01",
          "supported" => [@modern_version]
        })

      assert {:send, retry, retrying} = Negotiation.handle_error(state, request, error)
      assert retry.params["_meta"][@version_key] == @modern_version
      assert retrying.peer_versions == [@modern_version]
      assert retrying.negotiation_status == :discovering
    end

    test "auto fails -32022 when no mutual modern version exists" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => @modern_version,
          "supported" => ["2099-01-01"]
        })

      assert {:error, %Error{reason: :unsupported_protocol_version}, failed} =
               Negotiation.handle_error(state, request, error)

      assert failed.negotiation_status == :failed
    end

    test "auto retries an offered requested version once and then stops" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => @modern_version,
          "supported" => [@modern_version]
        })

      assert {:send, retry, retrying} = Negotiation.handle_error(state, request, error)
      assert retry.params["_meta"][@version_key] == @modern_version
      assert retrying.unsupported_version_retries == MapSet.new([@modern_version])

      retry_request = request(retry)

      assert {:error, %Error{reason: :unsupported_protocol_version}, failed} =
               Negotiation.handle_error(retrying, retry_request, error)

      assert failed.negotiation_status == :failed
    end

    test "a pinned modern version surfaces -32022 without retrying" do
      state = state(@modern_version, STDIO)
      request = request(discover_operation(@modern_version))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => @modern_version,
          "supported" => [@modern_version]
        })

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.negotiation_status == :failed
    end

    for malformed_data <- [
          [],
          %{"supported" => [@modern_version]},
          %{"requested" => 42, "supported" => [@modern_version]},
          %{"requested" => "different-version", "supported" => [@modern_version]},
          %{"requested" => "2099-01-01"},
          %{"requested" => "2099-01-01", "supported" => @modern_version},
          %{"requested" => "2099-01-01", "supported" => [@modern_version, 42]}
        ] do
      test "malformed -32022 data #{inspect(malformed_data)} is terminal", %{} do
        state = state(:auto, STDIO)
        request = request(discover_operation("2099-01-01"))

        error = %Error{
          code: -32_022,
          reason: :unsupported_protocol_version,
          message: "Unsupported protocol version",
          data: unquote(Macro.escape(malformed_data))
        }

        assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
        assert failed.negotiation_status == :failed
      end
    end

    test "a valid -32022 with an empty supported list is terminal" do
      state = state(:auto, STDIO)
      request = request(discover_operation("2099-01-01"))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => "2099-01-01",
          "supported" => []
        })

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.negotiation_status == :failed
    end

    for reason <- [:parse_error, :invalid_request, :method_not_found, :invalid_params] do
      test "stdio auto falls back to legacy initialize on #{reason}", %{} do
        state = state(:auto, STDIO)
        request = request(discover_operation(@modern_version))
        error = Error.protocol(unquote(reason))

        assert {:send, operation, fallback} = Negotiation.handle_error(state, request, error)
        assert operation.method == "initialize"
        assert fallback.era == :legacy
        assert fallback.negotiation_status == :initializing
      end
    end

    test "stdio treats a malformed modern response as terminal instead of legacy proof" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      error = Error.transport(:malformed_response, %{message: "Malformed JSON-RPC error response"})

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.negotiation_status == :failed
      assert failed.negotiation_error == error
      assert failed.era == :modern
    end

    test "stdio auto falls back to legacy initialize on discovery timeout" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      error = Error.transport(:request_timeout)

      assert {:send, operation, fallback} = Negotiation.handle_error(state, request, error)
      assert operation.method == "initialize"
      assert fallback.era == :legacy
    end

    for reason <- [:header_mismatch, :missing_client_capability] do
      test "stdio recognizes modern #{reason} and does not fall back", %{} do
        state = state(:auto, STDIO)
        request = request(discover_operation(@modern_version))
        error = Error.for_version(@modern_version, unquote(reason))

        assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
        assert failed.negotiation_status == :failed
        assert failed.era == :modern
      end
    end

    test "stdio surfaces arbitrary application errors" do
      state = state(:auto, STDIO)
      request = request(discover_operation(@modern_version))
      error = Error.execution("application failed")

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.negotiation_status == :failed
    end

    for status <- [400, 404] do
      test "HTTP auto falls back on unrecognized #{status} responses", %{} do
        state = state(:auto, StreamableHTTP)
        request = request(discover_operation(@modern_version))

        error =
          Error.transport(:send_failure, %{
            original_reason: {:http_error, unquote(status), "legacy endpoint"}
          })

        assert {:send, operation, fallback} = Negotiation.handle_error(state, request, error)
        assert operation.method == "initialize"
        assert fallback.era == :legacy
      end
    end

    test "pinned HTTP modern negotiation never falls back on an unrecognized 400" do
      state = state(@modern_version, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      error =
        Error.transport(:send_failure, %{
          original_reason: {:http_error, 400, "legacy endpoint"}
        })

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.era == :modern
      assert failed.negotiation_status == :failed
    end

    test "HTTP preserves the transport error for a JSON-RPC-looking 404 response" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{"code" => -32_601, "message" => "Method not found"}
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 404, body}})

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.era == :modern
      assert failed.negotiation_status == :failed
    end

    test "HTTP auto falls back when discovery returns method not found directly" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))
      error = Error.protocol(:method_not_found)

      assert {:send, operation, fallback} =
               Negotiation.handle_error(state, request, error)

      assert operation.method == "initialize"
      assert operation.params["protocolVersion"] == Protocol.fallback_version()
      assert fallback.era == :legacy
      assert fallback.negotiation_status == :initializing
      assert fallback.protocol_version == Protocol.fallback_version()
      assert fallback.negotiated_version == nil
    end

    test "HTTP auto falls back when a 400 response contains method not found" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{"code" => -32_601, "message" => "Method not found"}
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

      assert {:send, operation, fallback} =
               Negotiation.handle_error(state, request, error)

      assert operation.method == "initialize"
      assert operation.params["protocolVersion"] == Protocol.fallback_version()
      assert fallback.era == :legacy
      assert fallback.negotiation_status == :initializing
      assert fallback.protocol_version == Protocol.fallback_version()
      assert fallback.negotiated_version == nil
    end

    test "a pinned HTTP modern version surfaces direct method not found without downgrading" do
      state = state(@modern_version, StreamableHTTP)
      request = request(discover_operation(@modern_version))
      error = Error.protocol(:method_not_found)

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.era == :modern
      assert failed.negotiation_status == :failed
      assert failed.protocol_version == @modern_version
      assert failed.negotiated_version == nil
    end

    test "a pinned HTTP modern version surfaces wrapped method not found without downgrading" do
      state = state(@modern_version, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{"code" => -32_601, "message" => "Method not found"}
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

      assert {:error, %Error{reason: :method_not_found}, failed} =
               Negotiation.handle_error(state, request, error)

      assert failed.era == :modern
      assert failed.negotiation_status == :failed
      assert failed.protocol_version == @modern_version
      assert failed.negotiated_version == nil
    end

    test "HTTP auto keeps direct invalid params terminal" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))
      error = Error.protocol(:invalid_params)

      assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
      assert failed.era == :modern
      assert failed.negotiation_status == :failed
      assert failed.negotiation_error == error
    end

    test "HTTP auto keeps wrapped invalid params terminal" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{"code" => -32_602, "message" => "Invalid params"}
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

      assert {:error, %Error{reason: :invalid_params} = decoded_error, failed} =
               Negotiation.handle_error(state, request, error)

      assert failed.era == :modern
      assert failed.negotiation_status == :failed
      assert failed.negotiation_error == decoded_error
    end

    test "HTTP retries a recognized -32022 response when a mutual version exists" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation("2099-01-01"))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{
            "code" => -32_022,
            "message" => "Unsupported protocol version",
            "data" => %{
              "requested" => "2099-01-01",
              "supported" => [@modern_version]
            }
          }
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

      assert {:send, retry, retrying} = Negotiation.handle_error(state, request, error)
      assert retry.params["_meta"][@version_key] == @modern_version
      assert retrying.era == :modern
    end

    test "HTTP treats malformed -32022 data as terminal without retrying" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation("2099-01-01"))

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "discover",
          "error" => %{
            "code" => -32_022,
            "message" => "Unsupported protocol version",
            "data" => []
          }
        })

      error =
        Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

      assert {:error, %Error{reason: :unsupported_protocol_version, data: []}, failed} =
               Negotiation.handle_error(state, request, error)

      assert failed.negotiation_status == :failed
      assert failed.peer_versions == []
    end

    test "HTTP retries an asynchronously delivered -32022 response" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation("2099-01-01"))

      error =
        Error.for_version(@modern_version, :unsupported_protocol_version, %{
          "requested" => "2099-01-01",
          "supported" => [@modern_version]
        })

      assert {:send, retry, retrying} = Negotiation.handle_error(state, request, error)
      assert retry.params["_meta"][@version_key] == @modern_version
      assert retrying.peer_versions == [@modern_version]
    end

    for status <- [401, 403, 405, 500] do
      test "HTTP #{status} does not decode a valid -32022 body", %{} do
        state = state(:auto, StreamableHTTP)
        request = request(discover_operation("2099-01-01"))

        body =
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "discover",
            "error" => %{
              "code" => -32_022,
              "message" => "Unsupported protocol version",
              "data" => %{
                "requested" => "2099-01-01",
                "supported" => [@modern_version]
              }
            }
          })

        error =
          Error.transport(:send_failure, %{
            original_reason: {:http_error, unquote(status), body}
          })

        assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
        assert failed.negotiation_status == :failed
        assert failed.era == :modern
      end
    end

    for {status, body} <- [
          {401, "unauthorized"},
          {403, "forbidden"},
          {405, "method not allowed"},
          {500, "server error"},
          {400, ~s({"jsonrpc":"2.0","error":"malformed"})}
        ] do
      test "HTTP surfaces #{status} with body #{inspect(body)}", %{} do
        state = state(:auto, StreamableHTTP)
        request = request(discover_operation(@modern_version))

        error =
          Error.transport(:send_failure, %{
            original_reason: {:http_error, unquote(status), unquote(body)}
          })

        assert {:error, %Error{}, failed} = Negotiation.handle_error(state, request, error)
        assert failed.negotiation_status == :failed
        assert failed.era == :modern
      end
    end

    test "HTTP surfaces network and timeout failures" do
      state = state(:auto, StreamableHTTP)
      request = request(discover_operation(@modern_version))

      for error <- [
            Error.transport(:send_failure, %{original_reason: :econnrefused}),
            Error.transport(:request_timeout)
          ] do
        assert {:error, ^error, failed} = Negotiation.handle_error(state, request, error)
        assert failed.negotiation_status == :failed
      end
    end
  end

  defp state(preference, layer) do
    State.new(%{
      client_info: %{"name" => "TestClient", "version" => "1.0.0"},
      capabilities: %{"roots" => %{}},
      protocol_version: preference,
      transport: %{layer: layer, name: :transport},
      timeout: 1_000
    })
  end

  defp discover_operation(version) do
    %Backplane.McpProtocol.Client.Operation{
      method: "server/discover",
      params: %{
        "_meta" => %{
          @version_key => version,
          @capabilities_key => %{}
        }
      },
      timeout: 1_000
    }
  end

  defp valid_discovery_result do
    %{
      "resultType" => "complete",
      "supportedVersions" => [@modern_version],
      "capabilities" => %{},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }
  end

  defp request(operation) do
    Request.new(%{
      id: "negotiation-request",
      method: operation.method,
      params: operation.params,
      from: {self(), make_ref()},
      timer_ref: make_ref()
    })
  end
end
