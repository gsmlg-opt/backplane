defmodule Backplane.AiProtocolTest do
  use Backplane.AiProtocol.Case, async: true

  alias Backplane.AiProtocol.{
    Capability,
    ContentBlock,
    Error,
    ExecutionContext,
    Message,
    ProviderState,
    Request,
    Response,
    Serialization,
    ToolCall,
    Usage,
    Validation
  }

  alias Backplane.AiProtocol.Affinity

  describe "request and execution context boundary" do
    test "builds portable request and never accepts execution context from payload" do
      request =
        Request.new(%{
          model: "public-model",
          input: [
            %{role: :system, content: [%{type: :text, text: "system"}]},
            %{role: :user, content: [%{type: :text, text: "hello"}]}
          ],
          correlation: %{"request" => "r1"},
          permitted_downgrades: ["max_output_tokens"]
        })

      assert {:ok, %Request{}} = request

      assert {:error, %Error{kind: :invalid_request}} =
               ExecutionContext.new(%{
                 principal: "user",
                 resolved_endpoint: "https://api.example"
               })

      assert {:error, %Error{}} = ExecutionContext.from_portable_payload(%{principal: "attacker"})
    end

    test "preserves role, block order, parallel call IDs, failed results, refusals, and output limits" do
      {:ok, request} =
        Request.new(%{
          model: %{selector: "provider/model"},
          input: [
            %{role: :system, content: [%{type: :text, text: "system"}]},
            %{role: :developer, content: [%{type: :text, text: "developer"}]},
            %{
              role: :user,
              content: [%{type: :text, text: "first"}, %{type: :text, text: "second"}]
            },
            %{
              role: :assistant,
              content: [
                %{type: :text, text: "first"},
                %{
                  type: :tool_call,
                  tool_call: %{
                    id: "call-1",
                    name: "search",
                    raw_arguments: {:structured, %{"q" => "one"}}
                  }
                },
                %{
                  type: :tool_call,
                  tool_call: %{id: "call-2", name: "fetch", raw_arguments: {:json, "{}"}}
                }
              ]
            },
            %{
              role: :tool,
              tool_call_id: "call-1",
              status: :success,
              content: [%{type: :text, text: "ok"}]
            },
            %{
              role: :tool,
              tool_call_id: "call-2",
              status: :error,
              content: [%{type: :text, text: "failed"}]
            }
          ],
          tools: [%{name: "search", description: "Search", input_schema: %{"type" => "object"}}]
        })

      assert %Request{} = request

      assert Enum.map(request.input, & &1.role) == [
               :system,
               :developer,
               :user,
               :assistant,
               :tool,
               :tool
             ]

      assert [%{text: "first"}, %{text: "second"}] = Enum.at(request.input, 2).content
      tool_calls = Enum.filter(Enum.at(request.input, 3).content, & &1.tool_call)
      assert [%{tool_call: %{id: "call-1"}}, %{tool_call: %{id: "call-2"}}] = tool_calls
      assert :error = Enum.at(request.input, 5).status

      {:ok, refusal} =
        ContentBlock.new(%{type: :refusal, text: "not allowed", reason: "policy"})

      assert refusal.type == :refusal
      assert refusal.reason == "policy"

      {:ok, response} =
        Response.new(%{
          output: [%{type: :text, text: "partial"}],
          stop_reason: :max_output_tokens,
          completeness: :partial,
          usage: %{mode: :snapshot, status: :partial, source: "upstream"}
        })

      assert response.stop_reason == :max_output_tokens
      assert response.completeness == :partial
      assert response.usage.status == :partial
      assert %Usage{} = response.usage
      assert response.usage.mode == :snapshot

      {:ok, response} =
        Response.new(%{
          output: [],
          stop_reason: :provider_specific_limit,
          completeness: :unknown,
          usage: nil
        })

      assert response.stop_reason == :provider_specific_limit
      assert response.completeness == :unknown
    end

    test "rejects incomplete tool arguments" do
      {:error, error} =
        ContentBlock.new(%{
          type: :tool_call,
          tool_call: %{id: "call-partial", name: "tool", raw_arguments: {:json, ""}}
        })

      assert error.kind == :invalid_request
      assert error.stage == :validation
    end

    test "keeps raw and validated tool arguments separate" do
      call =
        ToolCall.new(%{
          id: "call-raw",
          name: "read_file",
          raw_arguments: {:json, ~S({"path":"a"})}
        })

      assert {:ok, tool_call} = call
      assert tool_call.raw_arguments == {:json, ~S({"path":"a"})}
      assert tool_call.validated_arguments == nil

      {:ok, tool_call} =
        ToolCall.put_validated_arguments(tool_call, %{"path" => "a"})

      assert tool_call.validated_arguments == %{"path" => "a"}
    end
  end

  describe "provider state" do
    test "accepts provider state items in request input without execution context" do
      attrs = %{
        model: "public-model",
        input: [
          %{
            source_profile: "profile-a",
            source_protocol: "openai-responses",
            kind: "reasoning",
            payload: %{opaque: "state"},
            affinity: %{profile: "profile-a", protocol: "openai-responses"}
          },
          %{
            role: :user,
            content: [%{type: :text, text: "hello"}]
          }
        ]
      }

      assert {:ok, %Request{} = request} = Request.new(attrs)
      assert [%ProviderState{}, %Message{} = message] = request.input
      assert message.role == :user
    end

    test "public affinity omits credential identifiers and rejects them explicitly" do
      {:ok, state} =
        ProviderState.new(%{
          source_profile: "profile-a",
          source_protocol: "openai-responses",
          kind: "reasoning",
          payload: %{opaque: "state"},
          affinity: %{
            profile: "profile-a",
            protocol: "openai-responses",
            endpoint: "https://api.example",
            account: "acct_123"
          }
        })

      assert %{affinity: %{profile: "profile-a", account: "acct_123"}} = state
      assert :error = Map.fetch(state.affinity, :credential_id)

      assert {:error, %Error{}} =
               Affinity.new(%{
                 profile: "profile-a",
                 credential_id: "secret",
                 endpoint: "https://api.example"
               })
    end

    test "payload and reference are mutually exclusive and opaque blocks cannot be generically encoded" do
      assert {:error, %Error{}} =
               ProviderState.new(%{
                 source_profile: "profile-a",
                 source_protocol: "anthropic",
                 kind: "thinking",
                 payload: "p",
                 payload_reference: "r",
                 affinity: %{profile: "profile-a"}
               })

      assert {:error, %Error{}} =
               Serialization.to_json(%ContentBlock{
                 type: :provider_state,
                 state: %{opaque: "bytes"}
               })

      assert {:error, %Error{}} =
               Serialization.to_json(%ProviderState{
                 source_profile: "p",
                 source_protocol: "p",
                 kind: "k",
                 affinity: %{profile: "p"}
               })
    end

    test "rejects cross-origin state use by default" do
      {:ok, state} =
        ProviderState.new(%{
          source_profile: "profile-a",
          source_protocol: "openai-responses",
          kind: "reasoning",
          payload: "opaque",
          affinity: %{
            profile: "profile-a",
            protocol: "openai-responses",
            endpoint: "https://api.example"
          }
        })

      assert %Backplane.AiProtocol.Affinity{} = state.affinity
      assert state.affinity.profile == "profile-a"

      assert {:ok, %Backplane.AiProtocol.Affinity{} = affinity} =
               Backplane.AiProtocol.Affinity.new(%{
                 profile: "profile-b",
                 protocol: "anthropic"
               })

      assert affinity.profile == "profile-b"
    end
  end

  describe "tool definition" do
    test "accepts bounded schemas and rejects execution authorization fields" do
      {:ok, tool} =
        Backplane.AiProtocol.ToolDefinition.new(%{
          name: "read_file",
          description: "Read a file",
          input_schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
        })

      assert tool.name == "read_file"

      assert tool.input_schema == %{
               "type" => "object",
               "properties" => %{"path" => %{"type" => "string"}}
             }

      assert {:error, %Error{}} =
               Backplane.AiProtocol.ToolDefinition.new(%{
                 name: "read_file",
                 execute: true
               })
    end
  end

  describe "security boundaries" do
    test "rejects unknown critical fields and unauthorized execution fields" do
      assert {:error, %Error{}} =
               Request.new(%{model: "m", input: [], endpoint: "https://attacker.example"})

      assert {:error, %Error{}} = Request.new(%{model: "m", input: [], credential: "secret"})
      assert {:error, %Error{}} = Request.new(%{model: "m", input: [], principal: "attacker"})
    end

    test "preserves non-sensitive correlation metadata and rejects execution context" do
      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [],
          correlation: %{"request" => "r1", "attempt" => "a1"},
          permitted_downgrades: ["max_output_tokens"]
        })

      assert request.correlation == %{"request" => "r1", "attempt" => "a1"}

      assert {:error, %Error{}} =
               Request.new(%{
                 model: "public-model",
                 input: [],
                 transport: %{kind: "http"}
               })
    end

    test "rejects unknown fields represented as string keys in argument maps" do
      attrs = %{"type" => :text, "text" => "x", "malicious" => %{"new_atom" => "value"}}

      assert {:error, %Error{}} = ContentBlock.new(attrs)
    end

    test "rejects atom creation from string keys and values" do
      assert {:error, %Error{}} =
               Request.new(%{"model" => "m", "input" => [%{"role" => "user", "content" => []}]})

      assert {:error, %Error{}} =
               ToolCall.new(%{
                 id: "call",
                 name: "tool",
                 raw_arguments: {:structured, "not_existing_atom"}
               })
    end

    test "rejects deeply nested and oversized payloads" do
      nested = deep_map(64, %{})
      nested = Map.put(%{}, "vendor::data", nested)
      attrs = %{"type" => :text, "text" => "x"} |> Map.merge(nested)
      assert {:error, %Error{}} = ContentBlock.new(attrs)

      oversized = String.duplicate("x", Validation.default_limits().max_bytes + 1)
      oversized = Map.put(%{}, "vendor::data", oversized)
      attrs = %{"type" => :text, "text" => "x"} |> Map.merge(oversized)
      assert {:error, %Error{}} = ContentBlock.new(attrs)
    end

    test "permits bounded namespaced extensions and rejects bare keys" do
      attrs =
        %{"type" => :text, "text" => "allowed"}
        |> Map.put("vendor::metadata", %{"bounded" => true})

      {:ok, block} = ContentBlock.new(attrs)

      assert block.extensions == %{"vendor::metadata" => %{"bounded" => true}}

      assert {:error, %Error{}} =
               ContentBlock.new(%{
                 "type" => :text,
                 "text" => "bare",
                 "metadata" => %{"bounded" => true}
               })
    end

    test "JSON decoding creates no atoms and validates bounds" do
      nested = deep_map(40, %{})

      assert {:error, %Error{}} =
               Serialization.decode_and_validate(Jason.encode!(nested), fn _value ->
                 {:ok, :validated}
               end)

      assert {:error, %Error{}} =
               Serialization.decode_and_validate(nested, fn _value -> {:ok, :validated} end)

      assert {:ok, value} =
               Serialization.decode_and_validate(~S({"existing":"true"}), fn value ->
                 {:ok, value}
               end)

      assert is_binary(value["existing"])
    end

    test "serializes portable maps with atom keys and rejects opaque state" do
      assert {:ok, json} = Serialization.to_json(%{model: "model", max_tokens: 10})
      assert {:ok, decoded} = Serialization.from_json(json)
      assert decoded == %{"model" => "model", "max_tokens" => 10}
    end

    test "preserves UTF-8 text in JSON round trips" do
      assert {:ok, json} = Serialization.to_json(%{text: "héllo"})
      assert {:ok, decoded} = Serialization.from_json(json)
      assert decoded == %{"text" => "héllo"}
    end
  end

  describe "capability and usage" do
    test "preserves unknown capability state and explicit usage mode" do
      {:ok, capability} =
        Capability.new(%{
          name: "image_input",
          state: :unknown,
          source: "static_catalog",
          confidence: 0.5
        })

      assert capability.state == :unknown

      assert {:error, %Error{}} =
               Capability.new(%{name: "image_input", state: :missing, confidence: 0.5})

      {:ok, usage} =
        Usage.new(%{
          mode: :snapshot,
          status: :complete,
          source: "upstream",
          input_tokens: 10,
          output_tokens: 2
        })

      assert usage.mode == :snapshot

      {:ok, usage} =
        Usage.new(%{
          mode: :snapshot,
          status: :unknown,
          source: "upstream",
          input_tokens: nil,
          output_tokens: nil
        })

      assert usage.mode == :snapshot
      assert usage.status == :unknown
      assert usage.input_tokens == nil
      assert usage.output_tokens == nil

      assert {:error, %Error{}} =
               Usage.new(%{
                 mode: :snapshot,
                 status: :complete,
                 source: "upstream",
                 input_tokens: -1
               })
    end
  end

  describe "errors" do
    test "accepts structured sanitized diagnostics and bounded details" do
      {:ok, error} =
        Error.new(%{
          kind: :upstream_error,
          stage: :request,
          http_status: 502,
          provider_code: "provider_error",
          message: "Upstream returned an error",
          retry_hint: :retryable,
          retry_after_ms: 100,
          request_id: "req-1",
          attempt_id: "attempt-1",
          upstream_outcome: :known,
          partial_output: %{reason: "truncated"},
          compatibility: %{"field" => "diagnostic"},
          details: %{"sanitized" => true}
        })

      assert error.kind == :upstream_error
      assert error.upstream_outcome == :known
      assert error.partial_output == %{reason: "truncated"}
    end
  end

  describe "structured error semantics" do
    test "distinguishes cancellation from unknown upstream outcome" do
      {:ok, error} =
        Error.new(%{
          kind: :cancelled,
          stage: :execution,
          message: "local cancellation accepted",
          upstream_outcome: :unknown,
          partial_output: %{"completeness" => "incomplete"}
        })

      assert error.kind == :cancelled
      assert error.upstream_outcome == :unknown
      assert error.partial_output == %{"completeness" => "incomplete"}
    end

    test "does not treat retry hints as permission to replay" do
      {:ok, error} =
        Error.new(%{
          kind: :upstream_error,
          stage: :execution,
          message: "upstream failed",
          retry_hint: :retryable,
          upstream_outcome: :unknown
        })

      assert error.retry_hint == :retryable
      assert error.upstream_outcome == :unknown
    end

    test "preserves partial output and uncertainty in error semantics" do
      {:ok, error} =
        Error.new(%{
          kind: :cancelled,
          stage: :execution,
          message: "local cancellation accepted",
          upstream_outcome: :unknown,
          partial_output: %{"completeness" => "incomplete"}
        })

      assert error.kind == :cancelled
      assert error.upstream_outcome == :unknown
      assert error.partial_output == %{"completeness" => "incomplete"}
    end

    test "requires structured compatibility diagnostics" do
      {:ok, error} =
        Error.new(%{
          kind: :incompatible,
          stage: :translation,
          message: "cannot preserve provider state",
          compatibility: %{"field" => "affinity", "reason" => "cross_origin"}
        })

      assert error.compatibility == %{"field" => "affinity", "reason" => "cross_origin"}
    end

    test "does not include provider payloads in sanitized diagnostics" do
      {:ok, error} =
        Error.new(%{
          kind: :incompatible,
          stage: :translation,
          message: "cannot preserve provider state",
          details: %{"sanitized" => true}
        })

      assert error.details == %{"sanitized" => true}
      assert error.partial_output == nil
    end
  end

  describe "lifecycle reducer" do
    test "emits exactly one terminal for completed, incomplete, cancelled, and failed runs" do
      for {input, expected_status} <- [
            {:complete, :completed},
            {{:incomplete, :max_output_tokens}, :incomplete},
            {:cancel, :cancelled},
            {{:error, :upstream_error}, :failed}
          ] do
        lifecycle = Backplane.AiProtocol.Lifecycle.new()

        lifecycle =
          case input do
            :complete ->
              lifecycle
              |> Backplane.AiProtocol.Lifecycle.start_attempt()
              |> Backplane.AiProtocol.Lifecycle.finish(:complete, :stop)

            {:incomplete, stop_reason} ->
              lifecycle
              |> Backplane.AiProtocol.Lifecycle.start_attempt()
              |> Backplane.AiProtocol.Lifecycle.finish(:incomplete, stop_reason)

            :cancel ->
              lifecycle
              |> Backplane.AiProtocol.Lifecycle.start_attempt()
              |> Backplane.AiProtocol.Lifecycle.cancel(:unknown)

            {:error, kind} ->
              lifecycle
              |> Backplane.AiProtocol.Lifecycle.start_attempt()
              |> Backplane.AiProtocol.Lifecycle.fail(kind)
          end

        assert {:ok, %{status: ^expected_status}} =
                 Backplane.AiProtocol.Lifecycle.terminal(lifecycle)
      end
    end

    test "rejects late observations after terminal" do
      lifecycle =
        Backplane.AiProtocol.Lifecycle.new()
        |> Backplane.AiProtocol.Lifecycle.start_attempt()
        |> Backplane.AiProtocol.Lifecycle.finish(:complete, :stop)

      assert {:error, %Error{kind: :invalid_request}} =
               Backplane.AiProtocol.Lifecycle.start_attempt(lifecycle)

      assert {:error, %Error{}} =
               Backplane.AiProtocol.Lifecycle.finish(lifecycle, :complete, :stop)

      assert {:error, %Error{}} = Backplane.AiProtocol.Lifecycle.cancel(lifecycle, :unknown)
      assert {:error, %Error{}} = Backplane.AiProtocol.Lifecycle.fail(lifecycle, :upstream_error)
    end
  end

  describe "execution gate" do
    test "allows exactly one execution per handle" do
      gate = Backplane.AiProtocol.ExecutionGate.new()

      assert {:ok, handle} = Backplane.AiProtocol.ExecutionGate.open(gate)
      {:ok, claimed} = Backplane.AiProtocol.ExecutionGate.claim(handle)
      assert %Backplane.AiProtocol.ExecutionGate{claimed: true} = claimed

      assert {:error, %Error{}} = Backplane.AiProtocol.ExecutionGate.claim(claimed)

      {:ok, finished} = Backplane.AiProtocol.ExecutionGate.finish(claimed)
      assert %Backplane.AiProtocol.ExecutionGate{finished: true} = finished

      assert {:error, %Error{}} = Backplane.AiProtocol.ExecutionGate.claim(finished)
    end
  end

  describe "translation preflight" do
    test "plans compatible request and reports no diagnostics" do
      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [
            %{
              role: :user,
              content: [
                %{type: :text, text: "hello"},
                %{type: :image, data: "base64-data", reason: "inline image"}
              ]
            }
          ],
          tools: [
            %{
              name: "read_file",
              description: "Read a file",
              input_schema: %{"type" => "object"}
            }
          ],
          permitted_downgrades: []
        })

      source = %{
        protocol: "backplane.v1",
        capabilities: %{"text" => :supported, "image" => :supported, "tool_calls" => :supported}
      }

      target = %{
        protocol: "openai-chat",
        capabilities: %{"text" => :supported, "image" => :supported, "tool_calls" => :supported}
      }

      assert {:ok, %Backplane.AiProtocol.TranslationPlan{} = plan} =
               Backplane.AiProtocol.Translation.plan(request, source, target, %{})

      assert plan.request == request
      assert plan.diagnostics == []
      assert plan.downgrades == []
      assert plan.executable == true
    end

    test "rejects unsupported field without permission" do
      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [
            %{
              role: :user,
              content: [%{type: :image, data: "base64-data", reason: "inline image"}]
            }
          ],
          permitted_downgrades: []
        })

      source = %{
        protocol: "backplane.v1",
        capabilities: %{"image" => :supported}
      }

      target = %{
        protocol: "anthropic",
        capabilities: %{"image" => :unsupported}
      }

      assert {:error,
              %Error{
                kind: :incompatible,
                stage: :translation,
                compatibility: %{"field" => "image"}
              }} =
               Backplane.AiProtocol.Translation.plan(request, source, target, %{})
    end

    test "allows named downgrade with warning" do
      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [
            %{
              role: :user,
              content: [%{type: :image, data: "base64-data", reason: "inline image"}]
            }
          ],
          permitted_downgrades: ["image_to_text"]
        })

      source = %{
        protocol: "backplane.v1",
        capabilities: %{"image" => :supported}
      }

      target = %{
        protocol: "anthropic",
        capabilities: %{"image" => :unsupported}
      }

      assert {:ok, plan} =
               Backplane.AiProtocol.Translation.plan(
                 request,
                 source,
                 target,
                 %{}
               )

      assert plan.executable == true
      assert plan.downgrades == ["image"]
      assert plan.diagnostics != []
    end

    test "rejects unknown downgrade rule" do
      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [],
          permitted_downgrades: ["bogus_rule"]
        })

      source = %{protocol: "backplane.v1", capabilities: %{}}
      target = %{protocol: "openai-chat", capabilities: %{}}

      assert {:error, %Error{kind: :incompatible, stage: :translation}} =
               Backplane.AiProtocol.Translation.plan(request, source, target, %{})
    end

    test "rejects provider state with cross-origin affinity" do
      {:ok, state} =
        ProviderState.new(%{
          source_profile: "profile-a",
          source_protocol: "openai-responses",
          kind: "reasoning",
          payload: "opaque",
          affinity: %{
            profile: "profile-a",
            protocol: "openai-responses",
            endpoint: "https://api.example"
          }
        })

      {:ok, request} =
        Request.new(%{
          model: "public-model",
          input: [state]
        })

      source = %{
        protocol: "backplane.v1",
        capabilities: %{"provider_state" => :supported}
      }

      target = %{
        protocol: "anthropic",
        capabilities: %{"provider_state" => :supported}
      }

      assert {:error,
              %Error{
                kind: :incompatible,
                stage: :translation,
                compatibility: %{"field" => "affinity"}
              }} =
               Backplane.AiProtocol.Translation.plan(request, source, target, %{})
    end
  end

  describe "wire contract" do
    test "builds valid hello and welcome envelopes with negotiated limits" do
      assert {:ok, hello} =
               Backplane.AiProtocol.Wire.hello(%{
                 protocol: "backplane.ai.v1",
                 wire: %{major: 1, minor: 0}
               })

      assert hello.type == "hello"
      assert hello.wire == %{major: 1, minor: 0}

      assert {:ok, welcome} =
               Backplane.AiProtocol.Wire.welcome(%{
                 protocol: "backplane.ai.v1",
                 wire: %{major: 1, minor: 0},
                 limits: %{
                   inbound_request_bytes: 8_388_608,
                   data_event_bytes: 65_536,
                   initial_request_credit_bytes: 262_144,
                   pending_request_buffer_bytes: 524_288,
                   pending_connection_buffer_bytes: 8_388_608,
                   concurrent_requests: 8,
                   control_reserve_bytes: 65_536
                 },
                 extensions: [],
                 flow_control: :per_request_credit
               })

      assert welcome.type == "welcome"
      assert welcome.flow_control == :per_request_credit
      assert welcome.limits.initial_request_credit_bytes == 262_144
    end

    test "rejects hello version outside supported envelope" do
      assert {:error, %Error{kind: :incompatible, stage: :wire}} =
               Backplane.AiProtocol.Wire.hello(%{
                 protocol: "backplane.ai.v1",
                 wire: %{major: 0, minor: 9}
               })
    end

    test "builds command response and classifies terminal separately from control" do
      command = Backplane.AiProtocol.Wire.command_response(%{accepted: true, request_id: "req-1"})
      assert command.type == "command.response"
      assert command.terminal == false

      terminal =
        Backplane.AiProtocol.Wire.terminal(%{
          status: :cancelled,
          upstream_outcome: :unknown,
          output_completeness: :incomplete
        })

      assert terminal.type == "request.finished"
      assert terminal.terminal == true
    end

    test "rejects duplicate request ids without resubmission" do
      wire = Backplane.AiProtocol.Wire.new()

      {:ok, wire} = Backplane.AiProtocol.Wire.accept_request(wire, "request-1")

      assert {:error, %Error{kind: :invalid_request, stage: :wire}} =
               Backplane.AiProtocol.Wire.accept_request(wire, "request-1")

      {:ok, wire} = Backplane.AiProtocol.Wire.accept_request(wire, "request-2")
      assert Backplane.AiProtocol.Wire.seen_ids(wire) == ["request-1", "request-2"]
    end

    test "retires connection when bounded seen-id set exceeds capacity" do
      wire =
        Enum.reduce(1..33, Backplane.AiProtocol.Wire.new(), fn index, wire ->
          case Backplane.AiProtocol.Wire.accept_request(wire, "request-#{index}") do
            {:ok, wire} -> wire
            {:error, _error} -> wire
          end
        end)

      assert Backplane.AiProtocol.Wire.retire?(wire)
    end

    test "uses per-request byte credit for data envelopes" do
      wire = Backplane.AiProtocol.Wire.new()
      {:ok, wire} = Backplane.AiProtocol.Wire.grant_credit(wire, "request-1", 262_144)

      event_bytes = 65_536
      {:ok, wire} = Backplane.AiProtocol.Wire.consume_credit(wire, "request-1", event_bytes)
      assert Backplane.AiProtocol.Wire.credit(wire, "request-1") == 196_608

      {:error, %Error{kind: :invalid_request, stage: :wire}} =
        Backplane.AiProtocol.Wire.send_data(wire, "request-1", 200_000)
    end
  end

  defp deep_map(0, value), do: value

  defp deep_map(depth, value) do
    deep_map(depth - 1, %{"nested" => value})
  end
end
