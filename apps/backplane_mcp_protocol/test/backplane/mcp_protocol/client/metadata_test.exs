defmodule Backplane.McpProtocol.Client.MetadataTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.Metadata
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.Transport.RequestContext

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @log_level_key "io.modelcontextprotocol/logLevel"

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "attach/3" do
    test "adds required modern metadata while preserving existing metadata" do
      params = %{
        "query" => "weather",
        "_meta" => %{"progressToken" => 7, "existing" => true}
      }

      assert %{
               "query" => "weather",
               "_meta" => meta
             } = Metadata.attach(params, modern_state(), %{})

      assert meta[@protocol_version_key] == "2026-07-28"
      assert meta[@client_capabilities_key] == %{"roots" => %{}}
      assert meta[@client_info_key] == %{"name" => "TestClient", "version" => "1.0.0"}
      assert meta["progressToken"] == 7
      assert meta["existing"]
    end

    test "reserved modern metadata cannot be spoofed by caller or pre-existing metadata" do
      params = %{
        "_meta" => %{
          @protocol_version_key => "pre-existing",
          @client_capabilities_key => %{"spoofed" => true},
          @client_info_key => %{"name" => "Spoof", "version" => "0"},
          "trace" => "pre-existing"
        }
      }

      caller_meta = %{
        @protocol_version_key => "caller",
        @client_capabilities_key => %{"caller" => true},
        @client_info_key => %{"name" => "Caller", "version" => "0"},
        "trace" => "caller"
      }

      result = Metadata.attach(params, modern_state(), caller_meta)
      meta = result["_meta"]

      assert meta[@protocol_version_key] == "2026-07-28"
      assert meta[@client_capabilities_key] == %{"roots" => %{}}
      assert meta[@client_info_key] == %{"name" => "TestClient", "version" => "1.0.0"}
      assert meta["trace"] == "caller"
    end

    test "recursively normalizes metadata, capabilities, and client identity to unique string keys" do
      version_atom = String.to_atom(@protocol_version_key)
      capabilities_atom = String.to_atom(@client_capabilities_key)
      client_info_atom = String.to_atom(@client_info_key)

      state =
        modern_state(%{
          capabilities: %{
            :roots => %{listChanged: false},
            "roots" => %{"listChanged" => true}
          },
          client_info: %{
            :name => "Atom client",
            "name" => "String client",
            :version => "0",
            "version" => "2"
          }
        })

      params = %{
        :_meta => %{version_atom => "atom params", nested: %{same: "atom"}},
        "_meta" => %{
          @protocol_version_key => "string params",
          capabilities_atom => %{"spoofed" => true},
          client_info_atom => %{"name" => "Spoof", "version" => "0"},
          "nested" => %{:same => "atom", "same" => "string"}
        }
      }

      extra_meta = %{
        version_atom => "atom caller",
        @protocol_version_key => "string caller",
        capabilities_atom => %{"caller" => true}
      }

      result = Metadata.attach(params, state, extra_meta)
      meta = result["_meta"]

      refute Map.has_key?(result, :_meta)
      assert meta[@protocol_version_key] == "2026-07-28"
      assert meta[@client_capabilities_key] == %{"roots" => %{"listChanged" => true}}
      assert meta[@client_info_key] == %{"name" => "String client", "version" => "2"}
      assert meta["nested"] == %{"same" => "string"}
      assert recursively_string_keyed?(meta)
    end

    test "adds only valid optional client identity and log level" do
      state =
        modern_state(%{
          client_info: %{
            "name" => "TestClient",
            "version" => "1.0.0",
            "title" => "Test client",
            "description" => "Exercises metadata",
            "websiteUrl" => "https://example.test/client",
            "icons" => [
              %{
                "src" => "https://example.test/icon.svg",
                "mimeType" => "image/svg+xml",
                "sizes" => ["any"],
                "theme" => "dark"
              }
            ]
          },
          log_level: "info"
        })

      meta = Metadata.attach(%{}, state, %{})["_meta"]

      assert meta[@client_info_key] == state.client_info
      assert meta[@log_level_key] == "info"
    end

    test "omits invalid optional client identity and log level without raising" do
      invalid_client_info = [
        %{"name" => "missing-version"},
        %{"name" => "Client", "version" => "1", "websiteUrl" => 42},
        %{
          "name" => "Client",
          "version" => "1",
          "icons" => [%{"src" => "relative/icon.svg"}]
        }
      ]

      for client_info <- invalid_client_info do
        state = modern_state(%{client_info: client_info, log_level: "verbose"})
        meta = Metadata.attach(%{}, state, %{})["_meta"]

        refute Map.has_key?(meta, @client_info_key)
        refute Map.has_key?(meta, @log_level_key)
      end
    end

    test "leaves legacy params unchanged when there is no metadata" do
      params = %{"name" => "weather"}
      assert Metadata.attach(params, legacy_state(), %{}) == params
    end

    test "merges legacy metadata without adding modern reserved keys" do
      params = %{"_meta" => %{"existing" => true, "trace" => "old"}}
      result = Metadata.attach(params, legacy_state(), %{"trace" => "new"})

      assert result["_meta"] == %{"existing" => true, "trace" => "new"}
      refute Map.has_key?(result["_meta"], @protocol_version_key)
      refute Map.has_key?(result["_meta"], @client_capabilities_key)
      refute Map.has_key?(result["_meta"], @client_info_key)
    end
  end

  test "the public metadata option reaches the wire and generated progress wins" do
    test_pid = self()

    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, opts ->
      send(test_pid, {:sent, message, opts})
      :ok
    end)

    {:ok, client} =
      Client.start_link_server(
        name: Module.concat(__MODULE__, "MetadataClient"),
        transport: [layer: Backplane.McpProtocol.MockTransport, name: :metadata_transport],
        client_info: %{"name" => "TestClient", "version" => "1.0.0"},
        capabilities: %{"roots" => %{}},
        protocol_version: "2026-07-28",
        timeout: 1_000
      )

    allow(Backplane.McpProtocol.MockTransport, self(), client)

    version_atom = String.to_atom(@protocol_version_key)
    capabilities_atom = String.to_atom(@client_capabilities_key)
    client_info_atom = String.to_atom(@client_info_key)

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          negotiation_status: :ready,
          negotiated_version: "2026-07-28",
          capabilities: %{:roots => %{}, "roots" => %{"listChanged" => true}},
          client_info: %{
            :name => "Atom",
            "name" => "TestClient",
            :version => "0",
            "version" => "1.0.0"
          },
          server_capabilities: %{"tools" => %{}}
      }
    end)

    task =
      Task.async(fn ->
        Client.list_tools(client,
          meta: %{
            "trace" => "caller",
            "progressToken" => "spoofed",
            version_atom => "spoofed",
            capabilities_atom => %{"spoofed" => true},
            client_info_atom => %{"name" => "Spoof", "version" => "0"},
            nested: %{:same => "atom", "same" => "string"}
          },
          progress: [token: 7, callback: fn _, _, _ -> :ok end]
        )
      end)

    assert_receive {:sent, encoded, opts}, 1_000
    request = JSON.decode!(encoded)

    assert request["params"]["_meta"][@protocol_version_key] == "2026-07-28"

    assert request["params"]["_meta"][@client_capabilities_key] ==
             %{"roots" => %{"listChanged" => true}}

    assert request["params"]["_meta"][@client_info_key] ==
             %{"name" => "TestClient", "version" => "1.0.0"}

    assert request["params"]["_meta"]["trace"] == "caller"
    assert request["params"]["_meta"]["progressToken"] == 7
    assert request["params"]["_meta"]["nested"] == %{"same" => "string"}
    assert occurrence_count(encoded, @protocol_version_key) == 1
    assert occurrence_count(encoded, @client_capabilities_key) == 1
    assert occurrence_count(encoded, @client_info_key) == 1

    assert %RequestContext{method: "tools/list", params: params} = opts[:request_context]
    assert params == request["params"]

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => request["id"],
         "result" => %{"resultType" => "complete", "tools" => []}
       })}
    )

    assert {:ok, _response} = Task.await(task, 1_000)
    GenServer.stop(client)
  end

  test "modern request logs omit caller metadata and arguments" do
    test_pid = self()
    sentinel = "task7-private-request-sentinel"

    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, opts ->
      send(test_pid, {:sent_private_request, message, opts})
      :ok
    end)

    suffix = System.unique_integer([:positive])

    {:ok, client} =
      Client.start_link_server(
        name: Module.concat(__MODULE__, "LoggingClient#{suffix}"),
        transport: [layer: Backplane.McpProtocol.MockTransport, name: :logging_transport],
        client_info: %{"name" => "TestClient", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2026-07-28",
        timeout: 1_000
      )

    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          negotiation_status: :ready,
          negotiated_version: "2026-07-28",
          server_capabilities: %{"tools" => %{}}
      }
    end)

    log =
      capture_protocol_message_logs(fn ->
        task =
          Task.async(fn ->
            Client.call_tool(
              client,
              "private-tool",
              %{"requestState" => sentinel},
              meta: %{"trace" => sentinel}
            )
          end)

        assert_receive {:sent_private_request, encoded, _opts}, 1_000
        request = JSON.decode!(encoded)
        assert request["params"]["arguments"]["requestState"] == sentinel
        assert request["params"]["_meta"]["trace"] == sentinel

        GenServer.cast(
          client,
          {:response,
           JSON.encode!(%{
             "jsonrpc" => "2.0",
             "id" => request["id"],
             "result" => %{"resultType" => "complete", "content" => []}
           })}
        )

        assert {:ok, _response} = Task.await(task, 1_000)
      end)

    refute log =~ sentinel
    GenServer.stop(client)
  end

  test "legacy request logs omit caller metadata and arguments" do
    test_pid = self()
    sentinel = "task7-private-legacy-request-sentinel"

    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, opts ->
      send(test_pid, {:sent_private_legacy_request, message, opts})
      :ok
    end)

    suffix = System.unique_integer([:positive])

    {:ok, client} =
      Client.start_link_server(
        name: Module.concat(__MODULE__, "LegacyLoggingClient#{suffix}"),
        transport: [layer: Backplane.McpProtocol.MockTransport, name: :legacy_logging_transport],
        client_info: %{"name" => "TestClient", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2025-11-25",
        timeout: 1_000
      )

    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :legacy,
          negotiation_status: :ready,
          negotiated_version: "2025-11-25",
          server_capabilities: %{"tools" => %{}}
      }
    end)

    log =
      capture_protocol_message_logs(fn ->
        task =
          Task.async(fn ->
            Client.call_tool(
              client,
              "private-tool",
              %{"requestState" => sentinel},
              meta: %{"trace" => sentinel}
            )
          end)

        assert_receive {:sent_private_legacy_request, encoded, _opts}, 1_000
        request = JSON.decode!(encoded)
        assert request["params"]["arguments"]["requestState"] == sentinel

        GenServer.cast(
          client,
          {:response,
           JSON.encode!(%{
             "jsonrpc" => "2.0",
             "id" => request["id"],
             "result" => %{"content" => []}
           })}
        )

        assert {:ok, _response} = Task.await(task, 1_000)
      end)

    refute log =~ sentinel
    GenServer.stop(client)
  end

  test "legacy initialized notification carries the exact negotiated request context" do
    test_pid = self()

    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, opts ->
      send(test_pid, {:sent_legacy_negotiation, message, opts})
      :ok
    end)

    suffix = System.unique_integer([:positive])

    {:ok, client} =
      Client.start_link_server(
        name: Module.concat(__MODULE__, "LegacyContextClient#{suffix}"),
        transport: [layer: Backplane.McpProtocol.MockTransport, name: :legacy_context_transport],
        client_info: %{"name" => "TestClient", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2025-06-18",
        timeout: 1_000
      )

    allow(Backplane.McpProtocol.MockTransport, self(), client)
    GenServer.cast(client, :negotiate)

    assert_receive {:sent_legacy_negotiation, initialize, initialize_opts}, 1_000
    initialize = JSON.decode!(initialize)

    assert %RequestContext{
             era: :legacy,
             method: "initialize",
             protocol_version: "2025-06-18"
           } = initialize_opts[:request_context]

    waiter = Task.async(fn -> Client.await_ready(client, timeout: 1_000) end)

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => initialize["id"],
         "result" => %{
           "protocolVersion" => "2025-11-25",
           "capabilities" => %{},
           "serverInfo" => %{"name" => "Legacy", "version" => "1"}
         }
       })}
    )

    assert_receive {:sent_legacy_negotiation, initialized, initialized_opts}, 1_000
    assert JSON.decode!(initialized)["method"] == "notifications/initialized"

    assert %RequestContext{
             era: :legacy,
             method: "notifications/initialized",
             protocol_version: "2025-11-25"
           } = initialized_opts[:request_context]

    assert :ok = Task.await(waiter, 1_000)
    GenServer.stop(client)
  end

  defp modern_state(overrides \\ %{}) do
    Map.merge(
      %State{
        client_info: %{"name" => "TestClient", "version" => "1.0.0"},
        capabilities: %{"roots" => %{}},
        protocol_version: "2026-07-28",
        negotiated_version: "2026-07-28",
        negotiation_status: :ready,
        era: :modern
      },
      overrides
    )
  end

  defp legacy_state do
    %State{
      client_info: %{"name" => "TestClient", "version" => "1.0.0"},
      capabilities: %{"roots" => %{}},
      protocol_version: "2025-11-25",
      negotiated_version: "2025-11-25",
      negotiation_status: :ready,
      era: :legacy
    }
  end

  defp recursively_string_keyed?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and recursively_string_keyed?(nested) end)
  end

  defp recursively_string_keyed?(value) when is_list(value), do: Enum.all?(value, &recursively_string_keyed?/1)
  defp recursively_string_keyed?(_value), do: true

  defp occurrence_count(encoded, key) do
    encoded
    |> String.split(~s("#{key}"))
    |> length()
    |> Kernel.-(1)
  end

  defp capture_protocol_message_logs(fun) do
    missing = make_ref()
    previous = Application.get_env(:backplane_mcp_protocol, :logging, missing)
    logging = if is_list(previous), do: previous, else: []
    Application.put_env(:backplane_mcp_protocol, :logging, Keyword.put(logging, :protocol_messages, :warning))

    try do
      capture_log([level: :warning], fun)
    after
      if previous == missing do
        Application.delete_env(:backplane_mcp_protocol, :logging)
      else
        Application.put_env(:backplane_mcp_protocol, :logging, previous)
      end
    end
  end
end
