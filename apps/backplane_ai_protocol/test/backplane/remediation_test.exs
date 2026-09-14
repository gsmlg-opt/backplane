defmodule Backplane.AiProtocol.RemediationTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{
    ContentBlock,
    Error,
    ExecutionContext,
    ExecutionGate,
    Message,
    OpenAIResponsesObserver,
    ProviderState,
    Request,
    Response,
    Serialization,
    ToolCall,
    ToolDefinition,
    Usage,
    Validation
  }

  describe "recursive validation" do
    test "accounts atom, string, and mixed keys without resetting aggregate bytes" do
      limits = %{max_bytes: 9, max_string_bytes: 8}
      assert :ok = Validation.term(%{:a => "12", "b" => "34"}, %{limits | max_bytes: 12})
      assert {:error, %Error{}} = Validation.term(%{:a => "1234", "b" => "5678"}, limits)

      assert {:error, %Error{}} =
               Validation.bounded_map(%{"only" => String.duplicate("x", 9)}, limits)
    end

    test "enforces depth, node count, unsupported terms, and exact boundaries" do
      assert :ok = Validation.term(%{"a" => "1234"}, %{max_bytes: 5, max_string_bytes: 4})

      assert {:error, %Error{}} =
               Validation.term(%{"a" => "12345"}, %{max_bytes: 5, max_string_bytes: 4})

      assert {:error, %Error{}} = Validation.term([1, 2, 3], %{max_nodes: 3})
      assert {:error, %Error{}} = Validation.term(self())
      assert {:error, %Error{}} = Validation.term(make_ref())
      assert {:error, %Error{}} = Validation.term(fn -> :ok end)
      assert {:error, %Error{}} = Validation.term(deep_map(40, nil))
    end
  end

  describe "serialization isolation" do
    test "rejects denied and unknown structs recursively" do
      opaque = %ExecutionContext{
        principal: "p",
        resolved_endpoint: "https://api.example",
        credential_binding: "secret"
      }

      assert {:error, %Error{}} = Serialization.to_json(%{"nested" => [opaque]})
      assert {:error, %Error{}} = Serialization.to_json(%{"nested" => [%URI{host: "secret"}]})
    end

    test "rejects normalized key collisions and caps encoded input before decode" do
      assert {:error, %Error{}} = Serialization.to_json(%{:model => "a", "model" => "b"})

      assert {:error, %Error{}} =
               Serialization.from_json(~S({"long":"value"}), max_encoded_bytes: 4)

      assert {:error, %Error{}} = Serialization.from_json(<<255>>)
    end

    test "serializes an approved portable request projection" do
      {:ok, request} =
        Request.new(%{model: "m", input: [%{role: :user, content: [%{type: :text, text: "hi"}]}]})

      assert {:ok, json} = Serialization.to_json(request)
      assert %{"model" => "m", "input" => [%{"role" => "user"}]} = Jason.decode!(json)
    end
  end

  describe "constructor composition" do
    test "composes validated canonical structs without trusting malformed structs" do
      {:ok, block} = ContentBlock.new(%{type: :text, text: "hello"})
      {:ok, message} = Message.new(%{role: :user, content: [%{type: :text, text: "hello"}]})
      {:ok, tool} = ToolDefinition.new(%{name: "lookup"})

      {:ok, call} =
        ToolCall.new(%{id: "call-1", name: "lookup", raw_arguments: {:json, "{}"}})

      {:ok, state} =
        ProviderState.new(%{
          source_profile: "openai-platform",
          source_protocol: "openai-responses",
          kind: "reasoning",
          affinity: %{profile: "openai-platform", protocol: "openai-responses"},
          payload: "opaque"
        })

      assert {:ok, %ContentBlock{tool_call: ^call}} =
               ContentBlock.new(%{type: :tool_call, tool_call: call})

      assert {:ok,
              %Request{input: [^message], tools: [^tool], provider_state_references: [^state]}} =
               Request.new(%{
                 model: "model",
                 input: [message],
                 tools: [tool],
                 provider_state_references: [state]
               })

      assert {:ok, %Response{output: [^block]}} =
               Response.new(%{
                 output: [block],
                 stop_reason: :stop,
                 completeness: :complete
               })

      assert {:ok, %Response{usage: %Usage{input_tokens: 1}}} =
               Response.new(%{
                 output: [],
                 stop_reason: :stop,
                 completeness: :complete,
                 usage: %Usage{
                   mode: :snapshot,
                   status: :complete,
                   source: "test",
                   input_tokens: 1
                 }
               })

      malformed = %ProviderState{
        source_profile: "openai-platform",
        source_protocol: "openai-responses",
        kind: "reasoning",
        affinity: nil,
        payload: "opaque"
      }

      assert {:error, %Error{kind: :invalid_request}} =
               Request.new(%{
                 model: "model",
                 input: [],
                 provider_state_references: [malformed]
               })

      malformed_usage = %Usage{
        mode: :snapshot,
        status: :complete,
        source: "test",
        input_tokens: -1
      }

      assert {:error, %Error{kind: :invalid_request}} =
               Response.new(%{
                 output: [],
                 stop_reason: :stop,
                 completeness: :complete,
                 usage: malformed_usage
               })
    end

    test "rejects colliding atom and string fields" do
      assert {:error, %Error{kind: :invalid_request}} =
               ContentBlock.new(%{"type" => :reasoning, type: :text, text: "hello"})
    end
  end

  test "wire handshake rejects invalid lifetime request id limits" do
    limits = %{
      inbound_request_bytes: 8_388_608,
      data_event_bytes: 65_536,
      initial_request_credit_bytes: 262_144,
      pending_request_buffer_bytes: 524_288,
      pending_connection_buffer_bytes: 8_388_608,
      concurrent_requests: 8,
      control_reserve_bytes: 65_536
    }

    for max_seen_ids <- [0, -1, "2"] do
      assert {:error, %Error{kind: :invalid_request}} =
               Backplane.AiProtocol.Wire.handshake(Backplane.AiProtocol.Wire.new(), %{
                 message_id: "welcome-1",
                 protocol: "backplane.ai.v1",
                 wire: %{major: 1, minor: 0},
                 limits: limits,
                 flow_control: :per_request_credit,
                 max_seen_ids: max_seen_ids
               })
    end
  end

  test "finish is absorbing for execution claims" do
    {:ok, gate} = ExecutionGate.open(ExecutionGate.new())
    {:ok, gate} = ExecutionGate.finish(gate)
    assert {:error, %Error{}} = ExecutionGate.claim(gate)
  end

  describe "provider state affinity" do
    test "checks references and every public binding with a positive preservation case" do
      {:ok, state} =
        ProviderState.new(%{
          source_profile: "openai-platform",
          source_protocol: "openai-responses",
          kind: "reasoning",
          payload: <<0, 1, 2, 255>>,
          affinity: %{
            profile: "openai-platform",
            protocol: "openai-responses",
            endpoint: "https://api.example",
            account: "acct",
            workspace: "ws",
            model: "gpt-test"
          }
        })

      {:ok, request} =
        Request.new(%{model: "gpt-test", input: [], provider_state_references: [state]})

      caps = %{"provider_state" => :supported}
      source = %{profile: "openai-platform", protocol: "openai-responses", capabilities: caps}

      target = %{
        profile: "openai-platform",
        protocol: "openai-responses",
        endpoint: "https://api.example",
        account: "acct",
        workspace: "ws",
        model: "gpt-test",
        capabilities: caps
      }

      assert {:ok, _plan} = Backplane.AiProtocol.Translation.plan(request, source, target, %{})
      assert hd(request.provider_state_references).payload == <<0, 1, 2, 255>>

      assert {:error, %Error{compatibility: %{"field" => "affinity"}}} =
               Backplane.AiProtocol.Translation.plan(
                 request,
                 source,
                 %{target | account: "other"},
                 %{}
               )
    end

    test "rejects contradictory source metadata and missing target binding" do
      {:ok, state} =
        ProviderState.new(%{
          source_profile: "p1",
          source_protocol: "openai-responses",
          kind: "reasoning",
          payload: "opaque",
          affinity: %{profile: "p2", protocol: "openai-responses"}
        })

      {:ok, request} = Request.new(%{model: "m", input: [state]})
      caps = %{"provider_state" => :supported}

      assert {:error, %Error{}} =
               Backplane.AiProtocol.Translation.plan(
                 request,
                 %{capabilities: caps},
                 %{profile: "p2", protocol: "openai-responses", capabilities: caps},
                 %{}
               )

      assert {:error, %Error{}} =
               Backplane.AiProtocol.Translation.plan(
                 request,
                 %{capabilities: caps},
                 %{protocol: "openai-responses", capabilities: caps},
                 %{}
               )
    end
  end

  test "retains string-keyed source and target identity in downgrade diagnostics" do
    {:ok, request} =
      Request.new(%{
        model: "m",
        input: [%{role: :user, content: [%{type: :image, data: "raw"}]}],
        permitted_downgrades: ["image_to_text"]
      })

    source = %{
      "protocol" => "backplane.v1",
      "profile" => "canonical",
      "capabilities" => %{"role_user" => :supported, "image" => :supported}
    }

    target = %{
      "protocol" => "anthropic",
      "profile" => "messages",
      "capabilities" => %{"role_user" => :supported, "image" => :unsupported}
    }

    policy = %{
      downgrade_rules: %{
        "image_to_text" => %{
          field: "image",
          revision: "1",
          effective: "caller_text",
          operation: %{op: "replace_image_with_caller_text"}
        }
      }
    }

    assert {:ok, plan} = Backplane.AiProtocol.Translation.plan(request, source, target, policy)

    assert [%{"source" => %{protocol: "backplane.v1", profile: "canonical"}} = diagnostic] =
             plan.diagnostics

    assert diagnostic["target"] == %{protocol: "anthropic", profile: "messages"}
  end

  describe "Responses observer" do
    test "preserves refusal and output-limit terminal meanings in non-streaming responses" do
      refusal =
        OpenAIResponsesObserver.observe_response(
          200,
          ~S({"id":"resp_refusal","status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"not allowed"}]}]})
        )

      assert refusal.protocol_terminal == :completed
      assert refusal.finish_reason == "refusal"

      output_limit =
        OpenAIResponsesObserver.observe_response(
          200,
          ~S({"id":"resp_limit","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}})
        )

      assert output_limit.protocol_terminal == :incomplete
      assert output_limit.finish_reason == "max_output_tokens"
    end

    test "frames split/coalesced CRLF SSE and retains trailing usage" do
      completed =
        ~S({"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":2},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":8}}})

      wire =
        "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hé\"}\r\n\r\ndata: #{completed}\n\n"

      <<first::binary-size(87), rest::binary>> = wire

      observer =
        OpenAIResponsesObserver.new()
        |> OpenAIResponsesObserver.feed(first)
        |> OpenAIResponsesObserver.feed(rest)
        |> OpenAIResponsesObserver.finish(:eof)

      facts = OpenAIResponsesObserver.facts(observer)
      assert facts.protocol_terminal == :completed
      assert facts.terminal_count == 1
      assert facts.input_tokens == 5
      assert facts.cached_tokens == 2
      assert facts.reasoning_tokens == 1
    end

    test "keeps malformed tool arguments non-executable and observation incomplete" do
      event =
        ~S(data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"tool","arguments":"{" ,"status":"completed"}})

      observer =
        OpenAIResponsesObserver.new()
        |> OpenAIResponsesObserver.feed(event <> "\n\n")
        |> OpenAIResponsesObserver.finish(:eof)

      assert [%{complete: false}] = OpenAIResponsesObserver.facts(observer).tool_calls
    end

    test "bounds unknown and oversized observation without inventing usage" do
      observer =
        OpenAIResponsesObserver.new(max_total_bytes: 8)
        |> OpenAIResponsesObserver.feed("123456789")

      facts = OpenAIResponsesObserver.facts(observer)
      assert facts.observation_status == :incomplete
      assert facts.usage_status == :unknown
      assert facts.input_tokens == nil
    end

    test "fails open for malformed nested SSE response values" do
      events = [
        ~S({"type":"response.created","response":1}),
        ~S({"type":"response.output_item.added","item":1}),
        ~S({"type":"response.output_item.done","item":[]}),
        ~S({"type":"response.in_progress","response":{"usage":{"input_tokens":2,"output_tokens":1,"input_tokens_details":1,"output_tokens_details":[]}}}),
        ~S({"type":"response.output_item.added","item":{"type":"function_call","id":"map","name":"tool","arguments":{"key":"value"}}}),
        ~S({"type":"response.output_item.added","item":{"type":"function_call","id":"integer","name":"tool","arguments":1}}),
        ~S({"type":"response.output_item.added","item":{"type":"function_call","id":"null","name":"tool","arguments":null}}),
        ~S({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":2,"output_tokens":1}}})
      ]

      observer =
        Enum.reduce(events, OpenAIResponsesObserver.new(), fn event, observer ->
          OpenAIResponsesObserver.feed(observer, "data: #{event}\n\n")
        end)
        |> OpenAIResponsesObserver.finish(:eof)

      facts = OpenAIResponsesObserver.facts(observer)
      assert facts.protocol_terminal == :completed
      assert facts.input_tokens == 2
      assert facts.output_tokens == 1
      assert facts.observation_status == :incomplete
      assert facts.usage_status == :partial
      assert Enum.all?(facts.tool_calls, &(&1.complete == false))
      assert facts.diagnostics != []
    end

    test "keeps malformed initial arguments incomplete through delta and done events" do
      events = [
        ~S({"type":"response.output_item.added","item":{"type":"function_call","id":"fc_bad","name":"tool","arguments":{"bad":true}}}),
        ~S({"type":"response.function_call_arguments.delta","item_id":"fc_bad","delta":"{\"ok\":"}),
        ~S({"type":"response.function_call_arguments.done","item_id":"fc_bad","arguments":"{\"ok\":true}"}),
        ~S({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}})
      ]

      facts =
        Enum.reduce(events, OpenAIResponsesObserver.new(), fn event, observer ->
          OpenAIResponsesObserver.feed(observer, "data: #{event}\n\n")
        end)
        |> OpenAIResponsesObserver.finish(:eof)
        |> OpenAIResponsesObserver.facts()

      assert facts.observation_status == :incomplete
      assert facts.usage_status == :partial
      assert [%{arguments: ~S({"ok":true}), complete: true}] = facts.tool_calls
      assert "invalid_tool_arguments" in facts.diagnostics
    end

    test "fails open for equivalent malformed non-streaming values" do
      malformed_documents = [
        %{"id" => "resp", "status" => "completed", "usage" => 1},
        %{
          "id" => "resp",
          "status" => "completed",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "input_tokens_details" => 1}
        },
        %{"id" => "resp", "status" => "completed", "output" => 1},
        %{
          "id" => "resp",
          "status" => "completed",
          "output" => [%{"type" => "function_call", "id" => "fc", "arguments" => nil}]
        },
        %{"id" => "resp", "status" => "completed", "output" => [1, []]}
      ]

      for document <- malformed_documents do
        body = Jason.encode!(document)
        facts = OpenAIResponsesObserver.observe_response(200, body)

        assert facts.bytes_seen == byte_size(body)
        assert facts.observation_status == :incomplete
        assert facts.diagnostics != []
      end
    end

    test "requires both valid counters and complete observation for complete usage" do
      partial =
        OpenAIResponsesObserver.observe_response(
          200,
          ~S({"status":"completed","usage":{"input_tokens":3,"output_tokens":-1}})
        )

      assert partial.input_tokens == 3
      assert partial.output_tokens == nil
      assert partial.usage_status == :partial
      assert partial.observation_status == :incomplete

      interrupted =
        OpenAIResponsesObserver.new()
        |> OpenAIResponsesObserver.feed(
          ~S(data: {"type":"response.in_progress","response":{"usage":{"input_tokens":3,"output_tokens":2}}}) <>
            "\n\n"
        )
        |> OpenAIResponsesObserver.finish(:eof)
        |> OpenAIResponsesObserver.facts()

      assert interrupted.input_tokens == 3
      assert interrupted.output_tokens == 2
      assert interrupted.usage_status == :partial
      assert interrupted.observation_status == :incomplete
    end

    test "bounds diagnostics and stops retaining chunks after the byte cap" do
      observer =
        [
          ~S({"type":"response.created","response":1}),
          ~S({"type":"response.function_call_arguments.delta"}),
          ~S({"type":"response.function_call_arguments.done"}),
          ~S({"type":"response.output_item.added","item":1}),
          ~S({"type":"response.in_progress","usage":1}),
          ~S({"type":"error","error":1}),
          ~S({"type":"unknown"})
        ]
        |> Enum.reduce(OpenAIResponsesObserver.new(max_diagnostics: 4), fn event, observer ->
          OpenAIResponsesObserver.feed(observer, "data: #{event}\n\n")
        end)

      observer =
        Enum.reduce(1..20, observer, fn _, observer ->
          OpenAIResponsesObserver.feed(observer, ~S(data: {"type":"unknown"}) <> "\n\n")
        end)

      facts = OpenAIResponsesObserver.facts(observer)
      assert length(facts.diagnostics) == 4
      assert List.last(facts.diagnostics) == "diagnostics_truncated"
      assert facts.diagnostics_truncated

      truncated =
        OpenAIResponsesObserver.new(max_total_bytes: 8, max_diagnostics: 4)
        |> OpenAIResponsesObserver.feed("123456789")

      before = OpenAIResponsesObserver.facts(truncated)

      after_facts =
        Enum.reduce(1..100, truncated, fn _, observer ->
          OpenAIResponsesObserver.feed(observer, "more malformed input")
        end)
        |> OpenAIResponsesObserver.facts()

      assert after_facts == before
      assert after_facts.input_truncated
      assert after_facts.observation_status == :incomplete
    end
  end

  defp deep_map(0, value), do: value
  defp deep_map(depth, value), do: deep_map(depth - 1, %{"nested" => value})
end
