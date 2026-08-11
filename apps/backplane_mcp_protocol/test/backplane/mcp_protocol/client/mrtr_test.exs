defmodule Backplane.McpProtocol.Client.MRTRTest do
  use Backplane.McpProtocol.MCP.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.InputHandler
  alias Backplane.McpProtocol.Client.MRTR
  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Telemetry

  @moduletag capture_log: true

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    test_pid = self()
    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _opts ->
      send(test_pid, {:mcp_send, message})
      :ok
    end)

    :ok
  end

  test "resolves every keyed roots, sampling, form, and URL input request" do
    test_pid = self()

    sampling_callback = fn params ->
      send(test_pid, {:sampled, params})

      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "sampled"},
         "model" => "test-model"
       }}
    end

    elicitation_callback = fn message, schema ->
      send(test_pid, {:elicited, message, schema})

      if schema["mode"] == "url" do
        {:accept, %{}}
      else
        {:accept, %{"answer" => "yes"}}
      end
    end

    state =
      %{
        "roots" => %{},
        "sampling" => %{"tools" => %{}},
        "elicitation" => %{"form" => %{}, "url" => %{}}
      }
      |> state()
      |> State.add_root("file:///workspace", "Workspace")
      |> State.add_root("file:///unnamed")
      |> State.set_sampling_callback(sampling_callback)
      |> State.set_elicitation_callback(elicitation_callback)

    input_requests = %{
      "roots" => %{"method" => "roots/list"},
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}],
          "maxTokens" => 32
        }
      },
      "form" => %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Continue?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"answer" => %{"type" => "string"}}
          }
        }
      },
      "url" => %{
        "method" => "elicitation/create",
        "params" => %{
          "mode" => "url",
          "message" => "Authorize",
          "url" => "https://example.test/authorize"
        }
      }
    }

    assert {:ok, responses} = InputHandler.resolve(input_requests, state)

    assert %{"uri" => "file:///workspace", "name" => "Workspace"} in responses["roots"]["roots"]
    assert %{"uri" => "file:///unnamed"} in responses["roots"]["roots"]

    assert responses["sample"]["model"] == "test-model"
    assert responses["form"] == %{"action" => "accept", "content" => %{"answer" => "yes"}}
    assert responses["url"] == %{"action" => "accept"}
    assert_receive {:sampled, _params}
    assert_receive {:elicited, "Continue?", %{"type" => "object"}}

    assert_receive {:elicited, "Authorize", %{"mode" => "url", "url" => "https://example.test/authorize"}}
  end

  test "rejects malformed bare requests and missing nested capabilities before callbacks" do
    test_pid = self()

    state =
      %{"sampling" => %{}, "elicitation" => %{}}
      |> state()
      |> State.set_sampling_callback(fn params ->
        send(test_pid, {:unexpected_sampling, params})
        {:error, "must not run"}
      end)

    malformed = [
      %{"bad" => %{"id" => 1, "method" => "roots/list"}},
      %{"bad" => %{"jsonrpc" => "2.0", "method" => "roots/list"}},
      %{"bad" => %{"method" => "unknown/request"}},
      %{"bad" => %{"method" => "sampling/createMessage", "params" => %{"messages" => []}}},
      %{"bad" => %{"method" => "elicitation/create", "params" => %{"mode" => "url"}}},
      %{7 => %{"method" => "roots/list"}}
    ]

    for requests <- malformed do
      assert {:error, %Error{reason: :invalid_params}} = InputHandler.resolve(requests, state)
    end

    assert {:error, %Error{code: -32_021, reason: :missing_client_capability}} =
             InputHandler.resolve(
               %{
                 "sample" => %{
                   "method" => "sampling/createMessage",
                   "params" => %{
                     "messages" => [],
                     "maxTokens" => 1,
                     "tools" => []
                   }
                 }
               },
               state
             )

    refute_receive {:unexpected_sampling, _}
  end

  for failure <- [:raise, :throw, :exit] do
    test "callback #{failure} is sanitized" do
      callback = fn _params ->
        case unquote(failure) do
          :raise -> raise "secret callback failure"
          :throw -> throw("secret callback failure")
          :exit -> exit("secret callback failure")
        end
      end

      state =
        %{"sampling" => %{}}
        |> state()
        |> State.set_sampling_callback(callback)

      requests = %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }

      assert {:error, %Error{} = error} = InputHandler.resolve(requests, state)
      refute inspect(error) =~ "secret callback failure"
    end
  end

  test "callback error tuples and malformed callback result schemas are sanitized" do
    sampling_request = %{
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 1}
      }
    }

    for callback <- [
          fn _params -> {:error, "secret provider error"} end,
          fn _params -> {:ok, %{"role" => "assistant", "content" => []}} end,
          fn _params ->
            {:ok,
             %{
               "role" => "assistant",
               "content" => %{"type" => "text", "text" => "bad envelope"},
               "model" => "test",
               "jsonrpc" => "2.0"
             }}
          end
        ] do
      state =
        %{"sampling" => %{}}
        |> state()
        |> State.set_sampling_callback(callback)

      assert {:error, %Error{} = error} = InputHandler.resolve(sampling_request, state)
      refute inspect(error) =~ "secret provider error"
      refute inspect(error) =~ "bad envelope"
    end

    elicitation_request = %{
      "form" => %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        }
      }
    }

    state =
      %{"elicitation" => %{}}
      |> state()
      |> State.set_elicitation_callback(fn _message, _schema ->
        {:accept, %{"name" => 42}}
      end)

    assert {:error, %Error{reason: :internal_error}} =
             InputHandler.resolve(elicitation_request, state)
  end

  test "roots and sampling outputs are validated against frozen wire shapes" do
    roots_request = %{"roots" => %{"method" => "roots/list"}}

    invalid_root_states = [
      %{state(%{"roots" => %{}}) | roots: %{"https://example.test" => %{uri: "https://example.test", name: nil}}},
      %{state(%{"roots" => %{}}) | roots: %{"file://bad space" => %{uri: "file://bad space", name: nil}}},
      %{state(%{"roots" => %{}}) | roots: %{"file:///ok" => %{uri: "file:///ok", name: 7}}}
    ]

    for invalid_state <- invalid_root_states do
      assert {:error, %Error{reason: :invalid_params}} =
               InputHandler.resolve(roots_request, invalid_state)
    end

    invalid_sampling_results = [
      %{
        "role" => "assistant",
        "content" => %{
          "type" => "tool_result",
          "toolUseId" => "call-1",
          "content" => [
            %{"type" => "resource_link", "name" => "bad", "uri" => "relative/path"}
          ]
        },
        "model" => "test"
      },
      %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "bad audience",
          "annotations" => %{"audience" => ["system"]}
        },
        "model" => "test"
      },
      %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "bad priority",
          "annotations" => %{"priority" => 1.1}
        },
        "model" => "test"
      },
      %{
        "role" => "assistant",
        "content" => %{
          "type" => "tool_result",
          "toolUseId" => "call-1",
          "content" => [],
          "structuredContent" => self()
        },
        "model" => "test"
      },
      %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "bad meta"},
        "model" => "test",
        "_meta" => %{"pid" => self()}
      }
    ]

    sampling_request = %{
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 1}
      }
    }

    for result <- invalid_sampling_results do
      invalid_state =
        %{"sampling" => %{}}
        |> state()
        |> State.set_sampling_callback(fn _params -> {:ok, result} end)

      assert {:error, %Error{reason: :internal_error}} =
               InputHandler.resolve(sampling_request, invalid_state)
    end
  end

  test "sampling resolver accepts the frozen modern result shapes" do
    result = %{
      "role" => "user",
      "content" => [
        %{"type" => "tool_use", "id" => "call-1", "name" => "lookup", "input" => %{}},
        %{
          "type" => "tool_result",
          "toolUseId" => "call-1",
          "content" => [%{"type" => "text", "text" => "done"}],
          "structuredContent" => %{"value" => 42},
          "isError" => false
        }
      ],
      "model" => "test-model",
      "stopReason" => "provider-specific-stop",
      "_meta" => %{"com.example/source" => "test"}
    }

    state =
      %{"sampling" => %{"tools" => %{}}}
      |> state()
      |> State.set_sampling_callback(fn _params -> {:ok, result} end)

    request = %{
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [],
          "maxTokens" => 1,
          "tools" => []
        }
      }
    }

    assert {:ok, %{"sample" => ^result}} = InputHandler.resolve(request, state)
  end

  test "retry params preserve the base request and distinguish empty-present inputRequests" do
    request =
      Request.new(%{
        id: "wire-1",
        method: "tools/call",
        from: {self(), make_ref()},
        timer_ref: make_ref(),
        params: %{
          "name" => "search",
          "arguments" => %{"query" => "elixir"},
          "inputResponses" => %{"stale" => true},
          "requestState" => "stale"
        }
      })

    assert {:ok, mrtr} =
             MRTR.prepare(request, %{
               "resultType" => "input_required",
               "inputRequests" => %{},
               "requestState" => "round-1"
             })

    assert MRTR.retry_params(mrtr, %{}) == %{
             "name" => "search",
             "arguments" => %{"query" => "elixir"},
             "inputResponses" => %{},
             "requestState" => "round-1"
           }

    assert {:ok, state_only} =
             MRTR.prepare(request, %{
               "resultType" => "input_required",
               "requestState" => "round-2"
             })

    refute Map.has_key?(MRTR.retry_params(state_only, %{}), "inputResponses")
    assert MRTR.retry_params(state_only, %{})["requestState"] == "round-2"
  end

  test "client retries with a fresh id, exact current round state, metadata, and original deadline" do
    test_pid = self()
    client = start_modern_client("MRTRRetry", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn params ->
        send(test_pid, {:sample_callback, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "answer"},
           "model" => "test-model"
         }}
      end)

    progress = [token: "progress-1", callback: fn _, _, _ -> :ok end]

    caller =
      Task.async(fn ->
        Client.call_tool(client, "search", %{"query" => "elixir"},
          timeout: 1_000,
          meta: %{"com.example/trace" => "trace-1"},
          progress: progress
        )
      end)

    first = receive_request("tools/call")
    first_deadline = pending_request(client, first["id"]).deadline

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 8}
        }
      },
      "requestState" => "opaque-round-1"
    })

    assert_receive {:sample_callback, %{"messages" => [], "maxTokens" => 8}}
    second = receive_request("tools/call")
    refute second["id"] == first["id"]
    assert pending_request(client, second["id"]).deadline == first_deadline
    assert second["params"]["name"] == "search"
    assert second["params"]["arguments"] == %{"query" => "elixir"}
    assert second["params"]["requestState"] == "opaque-round-1"
    assert Map.keys(second["params"]["inputResponses"]) == ["sample"]

    assert second["params"]["_meta"]["com.example/trace"] == "trace-1"
    assert second["params"]["_meta"]["progressToken"] == "progress-1"

    send_response(client, second["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample-round-2" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 4}
        }
      },
      "requestState" => "opaque-round-2"
    })

    assert_receive {:sample_callback, %{"messages" => [], "maxTokens" => 4}}
    third = receive_request("tools/call")
    refute third["id"] in [first["id"], second["id"]]
    assert third["params"]["requestState"] == "opaque-round-2"
    assert Map.keys(third["params"]["inputResponses"]) == ["sample-round-2"]
    refute Map.has_key?(third["params"]["inputResponses"], "sample")
    assert pending_request(client, third["id"]).deadline == first_deadline

    send_response(client, third["id"], %{
      "resultType" => "input_required",
      "requestState" => "opaque-round-3"
    })

    fourth = receive_request("tools/call")
    refute fourth["id"] in [first["id"], second["id"], third["id"]]
    assert fourth["params"]["requestState"] == "opaque-round-3"
    refute Map.has_key?(fourth["params"], "inputResponses")
    assert pending_request(client, fourth["id"]).deadline == first_deadline

    send_response(client, fourth["id"], %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "done"}],
      "isError" => false
    })

    assert {:ok, response} = Task.await(caller, 1_000)
    assert response.id == fourth["id"]
    assert response.result["resultType"] == "complete"
    assert :sys.get_state(client).pending_requests == %{}
    refute_receive {:mcp_send, _unexpected}
  end

  test "cancellation stops a blocked resolver and late messages do not kill the client" do
    test_pid = self()
    client = start_modern_client("MRTRCancel", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        send(test_pid, {:resolver_started, self()})

        receive do
          :release -> {:error, "released too late"}
        end
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 2_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:resolver_started, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)

    assert :ok = Client.cancel_request(client, first["id"], "test cancellation")
    assert {:error, %Error{reason: :request_cancelled}} = Task.await(caller, 1_000)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 1_000

    send(client, {make_ref(), {:ok, %{"late" => true}}})
    Process.sleep(10)
    assert Process.alive?(client)
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "MRTR cancellation cleans up locally even when cancellation send fails" do
    test_pid = self()

    stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _opts ->
      decoded = JSON.decode!(message)

      if decoded["method"] == "notifications/cancelled" do
        send(test_pid, {:failed_cancellation_send, decoded, self()})
        {:error, :cancellation_transport_down}
      else
        send(test_pid, {:mcp_send, message})
        :ok
      end
    end)

    client = start_modern_client("MRTRCancelSendFailure", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        send(test_pid, {:cancel_failure_resolver_started, self()})

        receive do
          :release -> {:error, "too late"}
        end
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 2_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:cancel_failure_resolver_started, resolver_pid}
    resolver_ref = Process.monitor(resolver_pid)

    assert :ok = Client.cancel_request(client, first["id"], "local cancellation")

    assert_receive {:failed_cancellation_send, %{"params" => %{"requestId" => request_id}}, transport_pid}
    transport_ref = Process.monitor(transport_pid)

    assert request_id == first["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Task.await(caller, 1_000)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 1_000
    assert_receive {:DOWN, ^transport_ref, :process, ^transport_pid, _reason}, 1_000
    assert Process.alive?(client)
    assert :sys.get_state(client).pending_requests == %{}
  end

  for failure_mode <- [:block, :raise, :exit] do
    @tag cancellation_failure_mode: failure_mode
    test "MRTR cancellation remains local when notification transport #{failure_mode}s", %{
      cancellation_failure_mode: failure_mode
    } do
      test_pid = self()

      stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _opts ->
        decoded = JSON.decode!(message)

        if decoded["method"] == "notifications/cancelled" do
          send(test_pid, {:cancellation_transport_entered, failure_mode, self()})

          case failure_mode do
            :block ->
              receive do
                :release_cancellation -> :ok
              end

            :raise ->
              raise "secret cancellation failure"

            :exit ->
              exit(:secret_cancellation_failure)
          end
        else
          send(test_pid, {:mcp_send, message})
          :ok
        end
      end)

      client = start_modern_client("MRTRLocalCancel#{failure_mode}", %{"sampling" => %{}})
      allow(Backplane.McpProtocol.MockTransport, self(), client)

      :ok =
        Client.register_sampling_callback(client, fn _params ->
          send(test_pid, {:local_cancel_resolver_started, failure_mode, self()})

          receive do
            :release -> {:error, "too late"}
          end
        end)

      caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 2_000) end)
      first = receive_request("tools/call")

      send_response(client, first["id"], %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "sample" => %{
            "method" => "sampling/createMessage",
            "params" => %{"messages" => [], "maxTokens" => 1}
          }
        }
      })

      assert_receive {:local_cancel_resolver_started, ^failure_mode, resolver_pid}
      resolver_ref = Process.monitor(resolver_pid)

      canceller =
        Task.async(fn ->
          Client.cancel_request(client, first["id"], "local cancellation")
        end)

      assert_receive {:cancellation_transport_entered, ^failure_mode, transport_pid}
      transport_ref = Process.monitor(transport_pid)
      prompt_cancel_result = Task.yield(canceller, 100)

      if failure_mode == :block do
        send(transport_pid, :release_cancellation)
      end

      if prompt_cancel_result == nil do
        _late_result = Task.await(canceller, 1_000)
      end

      assert prompt_cancel_result == {:ok, :ok}
      assert {:error, %Error{reason: :request_cancelled}} = Task.await(caller, 1_000)
      assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 1_000
      assert_receive {:DOWN, ^transport_ref, :process, ^transport_pid, _reason}, 1_000
      assert :sys.get_state(client).pending_requests == %{}
      assert Process.alive?(client)
      assert %{protocol_version: "2026-07-28"} = Client.get_protocol_info(client)
    end
  end

  test "modern cancelled notifications do not cancel ordinary MRTR work" do
    test_pid = self()
    client = start_modern_client("MRTRServerCancellationIgnored", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        send(test_pid, {:ignored_cancel_resolver_started, self()})

        receive do
          :release -> {:error, "cleanup"}
        end
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 2_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:ignored_cancel_resolver_started, resolver_pid}

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "notifications/cancelled",
         "params" => %{"requestId" => first["id"], "reason" => "server tried"}
       })}
    )

    _state_after_notification = :sys.get_state(client)
    assert Process.alive?(resolver_pid)
    assert pending_request(client, first["id"]).resolver_task.pid == resolver_pid
    assert Task.yield(caller, 0) == nil

    assert :ok = Client.cancel_request(client, first["id"], "test cleanup")
    assert {:error, %Error{reason: :request_cancelled}} = Task.await(caller, 1_000)
  end

  test "deadline expiry after a successful retry send cancels the fresh wire id" do
    test_pid = self()

    stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _opts ->
      decoded = JSON.decode!(message)

      if decoded["method"] == "tools/call" and
           Map.has_key?(decoded["params"], "inputResponses") do
        send(test_pid, {:delayed_retry_send, decoded, self()})

        receive do
          :release_delayed_retry -> :ok
        end
      else
        send(test_pid, {:mcp_send, message})
        :ok
      end
    end)

    client = start_modern_client("MRTRPostSendDeadline", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved"},
           "model" => "test"
         }}
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 100) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:delayed_retry_send, retry, sending_pid}
    refute retry["id"] == first["id"]
    Process.sleep(120)
    send(sending_pid, :release_delayed_retry)

    assert {:error, %Error{reason: :request_timeout}} = Task.await(caller, 1_000)
    cancellation = receive_request("notifications/cancelled")
    assert cancellation["params"]["requestId"] == retry["id"]
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "the original deadline times out and tears down blocked resolver work" do
    test_pid = self()
    client = start_modern_client("MRTRTimeout", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        send(test_pid, {:timeout_resolver_started, self()})

        receive do
          :release -> {:error, "too late"}
        end
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 120) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:timeout_resolver_started, resolver_pid}
    pending = pending_request(client, first["id"])
    supervisor_pid = pending.resolver_supervisor
    assert pending.deadline <= pending.start_time + 120

    resolver_ref = Process.monitor(resolver_pid)
    supervisor_ref = Process.monitor(supervisor_pid)

    assert {:error, %Error{reason: :request_timeout}} = Task.await(caller, 1_000)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, _reason}, 1_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor_pid, _reason}, 1_000

    send(client, {make_ref(), {:ok, %{"late" => true}}})
    Process.sleep(10)
    assert Process.alive?(client)
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "a retry send failure is sanitized and leaves the client alive and clean" do
    test_pid = self()

    stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _opts ->
      decoded = JSON.decode!(message)

      if decoded["method"] == "tools/call" and
           Map.has_key?(decoded["params"], "inputResponses") do
        send(test_pid, {:retry_send_attempt, decoded})
        {:error, {:secret_transport_reason, decoded["params"]}}
      else
        send(test_pid, {:mcp_send, message})
        :ok
      end
    end)

    client = start_modern_client("MRTRSendFailure", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved"},
           "model" => "test"
         }}
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 1_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:retry_send_attempt, _decoded}, 1_000
    assert {:error, %Error{reason: :send_failure} = error} = Task.await(caller, 1_000)
    refute inspect(error) =~ "secret_transport_reason"
    refute inspect(error) =~ "resolved"
    assert Process.alive?(client)
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "failure resolving any input request prevents the retry" do
    test_pid = self()
    client = start_modern_client("MRTRAllKeys", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn params ->
        send(test_pid, {:all_keys_callback, params["maxTokens"]})

        if params["maxTokens"] == 1 do
          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => "first"},
             "model" => "test"
           }}
        else
          {:error, "secret second failure"}
        end
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 1_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "a-first" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        },
        "b-second" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 2}
        }
      }
    })

    assert_receive {:all_keys_callback, 1}
    assert_receive {:all_keys_callback, 2}
    assert {:error, %Error{} = error} = Task.await(caller, 1_000)
    refute inspect(error) =~ "secret second failure"

    messages = drain_wire_messages([])

    refute Enum.any?(messages, fn message ->
             message["method"] == "tools/call" and
               is_map(message["params"]) and
               Map.has_key?(message["params"], "inputResponses")
           end)

    assert Process.alive?(client)
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "the original logical id cancels the active retry wire id" do
    client = start_modern_client("MRTRLogicalCancel", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved"},
           "model" => "test"
         }}
      end)

    caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 1_000) end)
    first = receive_request("tools/call")

    send_response(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    retry = receive_request("tools/call")
    assert :ok = Client.cancel_request(client, first["id"], "logical cancellation")
    assert {:error, %Error{reason: :request_cancelled}} = Task.await(caller, 1_000)

    cancellation = receive_request("notifications/cancelled")
    assert cancellation["params"]["requestId"] == retry["id"]
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "MRTR secrets never enter client logs or telemetry metadata" do
    old_logger_level = Logger.level()
    old_logger_env = Application.get_env(:logger, :level)
    old_log_enabled = Application.get_env(:backplane_mcp_protocol, :log)
    old_logging = Application.get_env(:backplane_mcp_protocol, :logging)

    Logger.configure(level: :debug)
    Application.put_env(:logger, :level, :debug)
    Application.put_env(:backplane_mcp_protocol, :log, true)

    Application.put_env(
      :backplane_mcp_protocol,
      :logging,
      protocol_messages: :debug,
      client_events: :debug
    )

    on_exit(fn ->
      Logger.configure(level: old_logger_level)
      restore_env(:logger, :level, old_logger_env)
      restore_env(:backplane_mcp_protocol, :log, old_log_enabled)
      restore_env(:backplane_mcp_protocol, :logging, old_logging)
    end)

    handler_id = "mrtr-secrecy-#{System.unique_integer([:positive])}"

    events =
      for event <- [
            Telemetry.event_client_request(),
            Telemetry.event_client_response(),
            Telemetry.event_client_error()
          ],
          do: [:backplane_mcp_protocol | event]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:mrtr_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    client = start_modern_client("MRTRSecrecy", %{"sampling" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved-response-sentinel"},
           "model" => "test"
         }}
      end)

    log =
      capture_log(fn ->
        caller = Task.async(fn -> Client.call_tool(client, "search", %{}, timeout: 1_000) end)
        first = receive_request("tools/call")

        send_response(client, first["id"], %{
          "resultType" => "input_required",
          "inputRequests" => %{
            "sample" => %{
              "method" => "sampling/createMessage",
              "params" => %{
                "messages" => [],
                "maxTokens" => 1,
                "systemPrompt" => "input-request-sentinel"
              }
            }
          },
          "requestState" => "request-state-sentinel"
        })

        retry = receive_request("tools/call")

        send_response(client, retry["id"], %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => "done"}],
          "isError" => false
        })

        assert {:ok, _response} = Task.await(caller, 1_000)
      end)

    telemetry = collect_telemetry([])

    assert log =~ "MCP message"
    assert log =~ "input_required"

    for secret <- [
          "request-state-sentinel",
          "input-request-sentinel",
          "resolved-response-sentinel"
        ] do
      refute log =~ secret
      refute inspect(telemetry) =~ secret
    end
  end

  test "legacy direct roots, sampling, and elicitation preserve params and wire responses" do
    test_pid = self()
    client = start_legacy_client("LegacyDirectInput", %{"roots" => %{}, "sampling" => %{}, "elicitation" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :sys.replace_state(client, fn state -> State.add_root(state, "file:///legacy", "Legacy") end)

    sampling_params = %{"messages" => [], "modelPreferences" => %{}}

    :ok =
      Client.register_sampling_callback(client, fn params ->
        send(test_pid, {:legacy_sampling_params, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "legacy sample"},
           "model" => "legacy-model"
         }}
      end)

    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    }

    elicitation_params = %{"message" => "Name?", "requestedSchema" => schema}

    :ok =
      Client.register_elicitation_callback(client, fn message, received_schema ->
        send(test_pid, {:legacy_elicitation_params, message, received_schema})
        {:accept, %{"name" => "legacy"}}
      end)

    direct_requests = [
      %{"jsonrpc" => "2.0", "id" => "roots", "method" => "roots/list", "params" => %{}},
      %{
        "jsonrpc" => "2.0",
        "id" => "sampling",
        "method" => "sampling/createMessage",
        "params" => sampling_params
      },
      %{
        "jsonrpc" => "2.0",
        "id" => "elicitation",
        "method" => "elicitation/create",
        "params" => elicitation_params
      }
    ]

    Enum.each(direct_requests, fn request ->
      GenServer.cast(client, {:response, JSON.encode!(request)})
    end)

    assert_receive {:legacy_sampling_params, ^sampling_params}
    assert_receive {:legacy_elicitation_params, "Name?", ^schema}

    responses = receive_responses_by_id(%{}, 3)

    assert responses["roots"]["result"] == %{
             "roots" => [%{"uri" => "file:///legacy", "name" => "Legacy"}]
           }

    assert responses["sampling"]["result"]["model"] == "legacy-model"

    assert responses["elicitation"]["result"] == %{
             "action" => "accept",
             "content" => %{"name" => "legacy"}
           }

    assert Process.alive?(client)
  end

  test "modern direct roots, sampling, and elicitation requests do not execute callbacks" do
    test_pid = self()
    client = start_modern_client("NoDirectInput", %{"roots" => %{}, "sampling" => %{}, "elicitation" => %{}})
    allow(Backplane.McpProtocol.MockTransport, self(), client)

    :ok =
      Client.register_sampling_callback(client, fn params ->
        send(test_pid, {:unexpected_sampling, params})
        {:error, "unexpected"}
      end)

    :ok =
      Client.register_elicitation_callback(client, fn message, schema ->
        send(test_pid, {:unexpected_elicitation, message, schema})
        :decline
      end)

    for {id, method, params} <- [
          {"roots", "roots/list", %{}},
          {"sampling", "sampling/createMessage", %{"messages" => [], "maxTokens" => 1}},
          {"elicitation", "elicitation/create",
           %{
             "message" => "No",
             "requestedSchema" => %{"type" => "object", "properties" => %{}}
           }}
        ] do
      GenServer.cast(
        client,
        {:response, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})}
      )
    end

    _state_after_requests = :sys.get_state(client)
    refute_receive {:unexpected_sampling, _}
    refute_receive {:unexpected_elicitation, _, _}
    refute_receive {:mcp_send, _wire_response}
    assert Process.alive?(client)
  end

  defp start_modern_client(name, capabilities) do
    client =
      start_supervised!(%{
        id: {Client, name},
        start:
          {Client, :start_link_server,
           [
             [
               transport: [layer: Backplane.McpProtocol.MockTransport, name: MockTransport],
               client_info: %{"name" => name, "version" => "1.0.0"},
               capabilities: capabilities,
               protocol_version: "2026-07-28"
             ]
           ]},
        restart: :temporary
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          negotiated_version: "2026-07-28",
          protocol_version: "2026-07-28",
          negotiation_status: :ready,
          server_capabilities: %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
      }
    end)

    client
  end

  defp start_legacy_client(name, capabilities) do
    client =
      start_supervised!(%{
        id: {Client, name},
        start:
          {Client, :start_link_server,
           [
             [
               transport: [layer: Backplane.McpProtocol.MockTransport, name: MockTransport],
               client_info: %{"name" => name, "version" => "1.0.0"},
               capabilities: capabilities,
               protocol_version: "2025-06-18"
             ]
           ]},
        restart: :temporary
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :legacy,
          negotiated_version: "2025-06-18",
          protocol_version: "2025-06-18",
          negotiation_status: :ready,
          server_capabilities: %{}
      }
    end)

    client
  end

  defp state(capabilities) do
    %{
      State.new(%{
        client_info: %{"name" => "MRTRTest"},
        capabilities: capabilities,
        protocol_version: "2026-07-28",
        transport: %{layer: MockTransport, name: MockTransport},
        timeout: 1_000
      })
      | era: :modern,
        negotiated_version: "2026-07-28"
    }
  end

  defp receive_request(method) do
    assert_receive {:mcp_send, raw}, 1_000
    request = JSON.decode!(raw)

    if request["method"] == method do
      request
    else
      receive_request(method)
    end
  end

  defp pending_request(client, id) do
    assert %Request{} = request = :sys.get_state(client).pending_requests[id]
    request
  end

  defp send_response(client, id, result) do
    GenServer.cast(
      client,
      {:response, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    )
  end

  defp drain_wire_messages(messages) do
    receive do
      {:mcp_send, raw} -> drain_wire_messages([JSON.decode!(raw) | messages])
    after
      50 -> Enum.reverse(messages)
    end
  end

  defp collect_telemetry(events) do
    receive do
      {:mrtr_telemetry, event, measurements, metadata} ->
        collect_telemetry([{event, measurements, metadata} | events])
    after
      50 -> Enum.reverse(events)
    end
  end

  defp receive_responses_by_id(responses, expected_count) when map_size(responses) == expected_count, do: responses

  defp receive_responses_by_id(responses, expected_count) do
    assert_receive {:mcp_send, raw}, 1_000
    response = JSON.decode!(raw)
    receive_responses_by_id(Map.put(responses, response["id"], response), expected_count)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
