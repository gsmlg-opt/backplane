Code.require_file("../../fixtures/sigma_builtin_tool_schemas.exs", __DIR__)
Code.require_file("../../fixtures/issue_46_tool_schemas.exs", __DIR__)

defmodule Backplane.AgentRuntime.ConversationTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, InputSchema, ToolRegistry}
  alias Backplane.AgentRuntime.Issue46ToolSchemas
  alias Backplane.AgentRuntime.SigmaBuiltinToolSchemas, as: SigmaSchemas

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool, operation, self()})

      receive do
        {:result, result} ->
          result

        :crash ->
          raise "scripted tool crash"

        :ask ->
          reply = operation.backend_context.interact.(%{kind: :permission})
          send(operation.backend_context.test, {:answer, reply})

          case reply do
            {:ok, :allow} -> {:ok, %{text: "allowed"}}
            _ -> {:error, Error.new(:forbidden, "denied")}
          end
      end
    end
  end

  defmodule EndedProvider do
    def stream(_, _), do: []
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == context.gate do
        send(context.test, {:commit_waiting, self()})

        receive do
          :commit -> EphemeralStore.store(context.table, run, meta)
          :fail -> {:error, Error.new(:execution_failure, "disk full")}
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  defmodule Hooks do
    def prompt(message, context) do
      send(context.test, {:hook, :prompt, message.content})
      if message.content == "block", do: {:error, "blocked"}, else: {:ok, message}
    end

    def stop(_messages, context) do
      send(context.test, {:hook, :stop})
      :stop
    end
  end

  defmodule ContinueHooks do
    def prompt(message, context) do
      send(context.test, :user_prompt_hook)
      {:ok, message}
    end

    def stop(messages, _context) do
      if Enum.any?(messages, &(&1[:content] == "synthetic")),
        do: :stop,
        else: {:continue, %{role: :user, content: "synthetic"}}
    end
  end

  defp start(opts \\ []) do
    {:ok, store} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "read",
        tool_revision: 1,
        schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        },
        safety: %{
          read_only: true,
          retry_safe: true,
          parallel_safe: false,
          requires_approval: Keyword.get(opts, :requires_approval, false)
        },
        backend: Backend,
        backend_context: %{test: self()}
      })

    opts =
      Keyword.merge(
        [
          run_id: "test",
          incarnation: 1,
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: registry,
          authority: %{caller: "test", run_id: "test", grants: ["read"], tool_revision: 1},
          work: 20,
          run_timeout: 5_000
        ],
        opts
      )

    pid = start_supervised!({Conversation, opts}, id: make_ref())
    {pid, store}
  end

  defp done(text), do: %{type: :response_completed, message: %{role: :assistant, content: text}}

  defp tool_response,
    do: [
      %{
        type: :tool_call_completed,
        tool_call: %{id: "tc1", name: "read", arguments: %{"path" => "x"}}
      },
      done("reading")
    ]

  defp todo_registry(schema) do
    ToolRegistry.register(%ToolRegistry{}, %{
      tool_name: "todo",
      tool_revision: 1,
      schema: schema,
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    })
  end

  defp default_annotated_registry do
    ToolRegistry.register(%ToolRegistry{}, %{
      tool_name: "unused-default",
      tool_revision: 1,
      schema: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "default" => 1}}
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    })
  end

  defp skill_registry do
    ToolRegistry.register(%ToolRegistry{}, %{
      tool_name: "skill",
      tool_revision: 1,
      schema: %{
        "type" => "object",
        "properties" => %{
          "locator" => %{"type" => "string"},
          "name" => %{"type" => "string"}
        },
        "anyOf" => [%{"required" => ["locator"]}, %{"required" => ["name"]}],
        "additionalProperties" => false
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    })
  end

  defp one_of_registry do
    ToolRegistry.register(%ToolRegistry{}, %{
      tool_name: "choose",
      tool_revision: 1,
      schema: %{
        "type" => "object",
        "properties" => %{
          "kind" => %{"type" => "string"},
          "value" => %{"type" => "string"}
        },
        "required" => ["kind", "value"],
        "additionalProperties" => false,
        "oneOf" => [
          %{"properties" => %{"kind" => %{"type" => "string", "enum" => ["left"]}}},
          %{"properties" => %{"kind" => %{"type" => "string", "enum" => ["right"]}}}
        ]
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    })
  end

  defp constrained_registry do
    ToolRegistry.register(%ToolRegistry{}, %{
      tool_name: "constrained",
      tool_revision: 1,
      schema: Issue46ToolSchemas.constrained(),
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    })
  end

  test "initial quarantine admission only sends accepted tools to the provider" do
    valid = %{
      tool_name: "read",
      tool_revision: 1,
      schema: %{"type" => "object"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    unsupported = %{
      tool_name: "legacy",
      tool_revision: 2,
      schema: %{"type" => "object", "$schema" => "https://example.invalid/schema"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    {:ok, first} = ToolRegistry.register(%ToolRegistry{}, valid)
    {:ok, registry} = ToolRegistry.register(first, unsupported)

    {pid, _store} =
      start(
        registry: registry,
        schema_admission: :quarantine,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["read", "legacy"],
          tool_revision: 1,
          tool_revisions: %{"read" => 1, "legacy" => 2}
        }
      )

    assert {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, %{tools: [%{name: "read"}]}, provider}
    send(provider, {:events, [done("answer")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "all-rejected quarantine stays text-only without retaining raw diagnostics" do
    secret = "schema-secret-sentinel"

    unsupported = %{
      tool_name: "legacy",
      tool_revision: 1,
      description: secret,
      schema: %{"type" => "object", "$schema" => "https://example.invalid/#{secret}"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, unsupported)

    {pid, store} =
      start(
        registry: registry,
        schema_admission: :quarantine,
        authority: %{caller: "test", run_id: "test", grants: ["legacy"], tool_revision: 1}
      )

    assert {:ok, _} = Conversation.prompt(pid, "text only")
    assert_receive {:provider, %{tools: []} = request, provider}
    refute inspect(request) =~ secret
    send(provider, {:events, [done("answer")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed} = event}
    refute inspect(event) =~ secret

    assert {:ok, record} = EphemeralStore.load(store, "test")
    refute inspect(record) =~ secret
    refute inspect(:sys.get_state(pid)) =~ secret
  end

  test "initial admission rejects authority bound to another run" do
    unsupported = %{
      tool_name: "legacy",
      tool_revision: 1,
      schema: %{"type" => "object", "$schema" => "https://example.invalid/schema"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, unsupported)

    assert {:error, %Error{class: :forbidden}} =
             Conversation.start_link(
               run_id: "test",
               registry: registry,
               schema_admission: :quarantine,
               authority: %{
                 caller: "test",
                 run_id: "other",
                 grants: ["legacy"],
                 tool_revision: 1
               }
             )
  end

  test "initial admission executes tools with heterogeneous descriptor revisions" do
    descriptors = [
      %{
        tool_name: "read",
        tool_revision: 1,
        schema: %{"type" => "object"},
        safety: %{read_only: true, retry_safe: true, parallel_safe: false},
        backend: Backend,
        backend_context: %{test: self()}
      },
      %{
        tool_name: "write",
        tool_revision: 2,
        schema: %{"type" => "object"},
        safety: %{read_only: false, retry_safe: false, parallel_safe: false},
        backend: Backend,
        backend_context: %{test: self()}
      }
    ]

    registry =
      Enum.reduce(descriptors, %ToolRegistry{}, fn descriptor, registry ->
        {:ok, registry} = ToolRegistry.register(registry, descriptor)
        registry
      end)

    {pid, _store} =
      start(
        registry: registry,
        schema_admission: :strict,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["read", "write"],
          tool_revisions: %{"read" => 1, "write" => 2}
        }
      )

    assert {:ok, _} = Conversation.prompt(pid, "write")
    assert_receive {:provider, %{tools: tools}, provider}
    assert Enum.map(tools, & &1.name) == ["read", "write"]

    send(provider, {
      :events,
      [
        %{type: :tool_call_completed, tool_call: %{id: "write-1", name: "write", arguments: %{}}},
        done("writing")
      ]
    })

    assert_receive {:tool, %{tool_name: "write", tool_revision: 2}, backend}
    send(backend, {:result, {:ok, %{text: "written"}}})
    assert_receive {:provider, _, final_provider}
    send(final_provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "accepted quarantine tools retain argument, approval, and durability gates" do
    valid = %{
      tool_name: "read",
      tool_revision: 1,
      schema: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      },
      safety: %{
        read_only: true,
        retry_safe: true,
        parallel_safe: false,
        requires_approval: true
      },
      backend: Backend,
      backend_context: %{test: self()}
    }

    unsupported = %{
      tool_name: "legacy",
      tool_revision: 1,
      schema: %{"type" => "object", "$schema" => "https://example.invalid/schema"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    {:ok, first} = ToolRegistry.register(%ToolRegistry{}, valid)
    {:ok, registry} = ToolRegistry.register(first, unsupported)

    {pid, store} =
      start(
        registry: registry,
        schema_admission: :quarantine,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["read", "legacy"],
          tool_revision: 1
        }
      )

    assert {:ok, _} = Conversation.prompt(pid, "read")
    assert_receive {:provider, %{tools: [%{name: "read"}]}, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "invalid", name: "read", arguments: %{"path" => 1}}
        },
        done("invalid")
      ]
    })

    refute_receive {:tool, %{tool_name: "read"}, _}, 20
    assert_receive {:provider, %{messages: messages}, retry_provider}
    assert List.last(messages).result.is_error == true

    send(retry_provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "valid", name: "read", arguments: %{"path" => "x"}}
        },
        done("valid")
      ]
    })

    assert_receive {:agent_runtime, "test",
                    %{type: :interaction_requested, interaction_id: interaction_id}}

    refute_receive {:tool, %{tool_name: "read"}, _}, 20
    assert :ok = Conversation.resolve(pid, interaction_id, :approved)
    assert_receive {:tool, %{tool_name: "read"}, backend}

    assert {:ok, record} = EphemeralStore.load(store, "test")
    assert Enum.any?(record.run.execution_intents, fn {_id, intent} -> intent.type == :tool end)

    send(backend, {:result, {:ok, %{text: "read"}}})
    assert_receive {:provider, _, final_provider}
    send(final_provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "incremental multi-step turn is persisted and settled once" do
    {pid, store} = start()
    assert {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, %{messages: [%{role: :user, content: "hello"}]}, worker}

    send(
      worker,
      {:events,
       [
         %{type: :content_text_delta, delta: "rea"},
         %{type: :content_thinking_delta, delta: "think"}
       ]}
    )

    assert_receive {:agent_runtime, "test", %{type: :content_text_delta, delta: "rea"}}
    assert_receive {:agent_runtime, "test", %{type: :content_thinking_delta}}
    send(worker, {:events, tool_response()})
    assert_receive {:tool, operation, tool}
    assert operation.arguments == %{"path" => "x"}
    assert operation.tool_call_id == "tc1"
    assert is_binary(operation.turn_id)
    send(tool, {:result, {:ok, %{text: "file"}}})
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).role == :tool

    send(
      next,
      {:events,
       [%{type: :usage_updated, usage: %{input: 3, output: 2}}, done("answer"), done("duplicate")]}
    )

    assert_receive {:agent_runtime, "test", %{type: :run_completed}}, 1_000
    refute_receive {:agent_runtime, "test", %{type: :run_completed}}, 20
    assert Conversation.status(pid).run.execution_budget.used == 3
    {:ok, %{run: run}} = EphemeralStore.load(store, "test")
    assert run.state == :completed
    assert run.context.conversation.messages == Conversation.status(pid).messages
  end

  test "Sigma Todo enum schema preflights, executes, and continues the provider" do
    schema = SigmaSchemas.todo()

    assert {:error, %Error{class: :validation, details: %{property: "action"}}} =
             InputSchema.validate(schema, %{})

    assert {:ok, registry} = todo_registry(schema)

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["todo"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "add the release regression")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "todo-add",
            name: "todo",
            arguments: %{
              "action" => "add",
              "content" => "release regression",
              "status" => "pending"
            }
          }
        },
        done("adding")
      ]
    })

    assert_receive {:tool, operation, tool}
    assert operation.tool_call_id == "todo-add"

    assert operation.arguments == %{
             "action" => "add",
             "content" => "release regression",
             "status" => "pending"
           }

    send(tool, {:result, {:ok, %{text: "added"}}})
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).role == :tool
    assert List.last(messages).result.is_error == false
    send(next, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "provider output accounting resets for each tool continuation" do
    {pid, _} = start(output_limit: 600)
    {:ok, _} = Conversation.prompt(pid, "use several tools")

    for {tool_id, final_text} <- [{"tc1", "first"}, {"tc2", "second"}] do
      assert_receive {:provider, _, provider}

      send(provider, {
        :events,
        [
          %{type: :content_text_delta, delta: String.duplicate("x", 300)},
          %{
            type: :tool_call_completed,
            tool_call: %{id: tool_id, name: "read", arguments: %{"path" => "x"}}
          },
          done(final_text)
        ]
      })

      assert_receive {:tool, _, tool}
      send(tool, {:result, {:ok, %{text: "read #{tool_id}"}}})
    end

    assert_receive {:provider, _, provider}

    send(
      provider,
      {:events,
       [%{type: :content_text_delta, delta: String.duplicate("x", 300)}, done("complete")]}
    )

    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "an unused default-annotated tool schema does not block the provider" do
    assert {:ok, registry} = default_annotated_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["unused-default"], tool_revision: 1}
      )

    assert {:ok, _} = Conversation.prompt(pid, "answer without tools")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "invalid Sigma Todo enum calls never invoke the backend and continue with an error" do
    assert {:ok, registry} = todo_registry(SigmaSchemas.todo())

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["todo"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "do an unsupported todo action")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "todo-invalid", name: "todo", arguments: %{"action" => "archive"}}
        },
        done("trying")
      ]
    })

    refute_receive {:tool, _, _}, 50
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).role == :tool
    assert List.last(messages).result.is_error == true
    assert List.last(messages).result.error.class == :validation
    send(next, {:events, [done("recovered")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "anyOf tool arguments invoke the backend exactly once when valid" do
    assert {:ok, registry} = skill_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["skill"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "load the assigned skill")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "skill-valid",
            name: "skill",
            arguments: %{"locator" => "assigned-skill"}
          }
        },
        done("loading")
      ]
    })

    assert_receive {:tool, %{tool_call_id: "skill-valid"}, tool}
    refute_receive {:tool, _, _}, 20
    send(tool, {:result, {:ok, %{text: "loaded"}}})
    assert_receive {:provider, _, next}
    send(next, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "anyOf tool arguments never invoke the backend when invalid" do
    assert {:ok, registry} = skill_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["skill"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "load an unspecified skill")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "skill-invalid", name: "skill", arguments: %{}}
        },
        done("loading")
      ]
    })

    refute_receive {:tool, _, _}, 50
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).result.error.class == :validation
    send(next, {:events, [done("recovered")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "an unused compatible oneOf catalog dispatches the provider" do
    assert {:ok, registry} = one_of_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["choose"], tool_revision: 1}
      )

    assert {:ok, _} = Conversation.prompt(pid, "answer without tools")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "valid oneOf object arguments invoke the backend exactly once" do
    assert {:ok, registry} = one_of_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["choose"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "choose left")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "choose-valid",
            name: "choose",
            arguments: %{"kind" => "left", "value" => "selected"}
          }
        },
        done("choosing")
      ]
    })

    assert_receive {:tool, %{tool_call_id: "choose-valid"}, tool}
    refute_receive {:tool, _, _}, 20
    send(tool, {:result, {:ok, %{text: "selected"}}})
    assert_receive {:provider, _, next}
    send(next, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "invalid oneOf object arguments never invoke the backend" do
    assert {:ok, registry} = one_of_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{caller: "test", run_id: "test", grants: ["choose"], tool_revision: 1}
      )

    {:ok, _} = Conversation.prompt(pid, "choose neither")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "choose-invalid",
            name: "choose",
            arguments: %{"kind" => "neither", "value" => "selected"}
          }
        },
        done("choosing")
      ]
    })

    refute_receive {:tool, _, _}, 50
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).result.error.class == :validation
    send(next, {:events, [done("recovered")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "an unused current MCP schema dispatches the provider" do
    assert {:ok, registry} = constrained_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["constrained"],
          tool_revision: 1
        }
      )

    assert {:ok, _} = Conversation.prompt(pid, "answer without tools")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "valid current MCP arguments invoke the backend exactly once" do
    assert {:ok, registry} = constrained_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["constrained"],
          tool_revision: 1
        }
      )

    {:ok, _} = Conversation.prompt(pid, "use constrained input")
    assert_receive {:provider, _, provider}

    arguments = %{
      "count" => 2,
      "code" => "none",
      "tags" => ["one"],
      "vars" => %{"x" => 10},
      "attachment" => %{"url" => "https://example.test"}
    }

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "constrained-valid", name: "constrained", arguments: arguments}
        },
        done("using")
      ]
    })

    assert_receive {:tool, %{tool_call_id: "constrained-valid"}, tool}
    refute_receive {:tool, _, _}, 20
    send(tool, {:result, {:ok, %{text: "used"}}})
    assert_receive {:provider, _, next}
    send(next, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "invalid current MCP arguments never invoke the backend" do
    assert {:ok, registry} = constrained_registry()

    {pid, _} =
      start(
        registry: registry,
        authority: %{
          caller: "test",
          run_id: "test",
          grants: ["constrained"],
          tool_revision: 1
        }
      )

    {:ok, _} = Conversation.prompt(pid, "use invalid constrained input")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "constrained-invalid",
            name: "constrained",
            arguments: %{
              "count" => 4,
              "code" => "none",
              "tags" => ["one"],
              "vars" => %{},
              "attachment" => %{}
            }
          }
        },
        done("using")
      ]
    })

    refute_receive {:tool, _, _}, 50
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).result.error.class == :validation
    send(next, {:events, [done("recovered")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "steering follows tool batch, follow-up follows turn completion" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "initial")
    assert_receive {:provider, _, provider}
    {:ok, _} = Conversation.steer(pid, "steer")
    {:ok, _} = Conversation.follow_up(pid, "follow")
    send(provider, {:events, tool_response()})
    assert_receive {:tool, _, tool}
    refute_receive {:provider, _, _}, 20
    send(tool, {:result, {:ok, %{text: "file"}}})
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).content == "steer"
    refute Enum.any?(messages, &(&1[:content] == "follow"))
    send(next, {:events, [done("steered")]})
    assert_receive {:agent_runtime, "test", %{type: :turn_completed}}
    assert_receive {:provider, %{messages: messages}, follow}
    assert List.last(messages).content == "follow"
    send(follow, {:events, [done("finished")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "correlated interactions allow and deny" do
    for decision <- [:allow, :deny] do
      {pid, _} = start()
      {:ok, _} = Conversation.prompt(pid, "question")
      assert_receive {:provider, _, provider}
      send(provider, {:events, tool_response()})
      assert_receive {:tool, _, tool}
      send(tool, :ask)
      assert_receive {:agent_runtime, "test", %{type: :interaction_requested, interaction_id: id}}
      assert {:error, %Error{}} = Conversation.resolve(pid, "stale", decision)
      assert :ok = Conversation.resolve(pid, id, decision)
      assert_receive {:answer, {:ok, ^decision}}
      assert {:error, %Error{}} = Conversation.resolve(pid, id, decision)
      assert_receive {:provider, %{messages: messages}, next}
      assert List.last(messages).result.is_error == (decision == :deny)
      send(next, {:events, [done("done")]})
      assert_receive {:agent_runtime, "test", %{type: :run_completed}}
    end
  end

  test "human interaction suspends run deadline and resumes with remaining budget" do
    {pid, _} = start(run_timeout: 500)
    {:ok, _} = Conversation.prompt(pid, "question")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:tool, _, tool}
    send(tool, :ask)
    assert_receive {:agent_runtime, "test", %{type: :interaction_requested, interaction_id: id}}

    pending = Conversation.status(pid)
    Process.sleep(600)
    assert Conversation.status(pid).phase == :waiting_interaction

    assert :ok = Conversation.resolve(pid, id, :allow)
    assert_receive {:answer, {:ok, :allow}}
    assert_receive {:provider, _, next}, 500
    assert Conversation.status(pid).run.deadline > pending.run.deadline
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}, 500
  end

  test "cancel provider, tool and interaction waits" do
    for phase <- [:provider, :tool, :interaction] do
      {pid, _} = start()
      {:ok, _} = Conversation.prompt(pid, "cancel")
      assert_receive {:provider, _, provider}

      worker =
        if phase == :provider do
          provider
        else
          send(provider, {:events, tool_response()})
          assert_receive {:tool, _, tool}

          if phase == :interaction do
            send(tool, :ask)
            assert_receive {:agent_runtime, "test", %{type: :interaction_requested}}
          end

          tool
        end

      monitor = Process.monitor(worker)
      assert :ok = Conversation.cancel(pid)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
      assert_receive {:agent_runtime, "test", %{type: :run_cancelled}}, 500
      assert Conversation.status(pid).phase == :terminal
    end
  end

  test "default busy prompt is a follow-up, and hooks retain prompt then stop order" do
    {pid, _} = start(hooks: Hooks)
    {:ok, _} = Conversation.prompt(pid, "first")
    assert_receive {:hook, :prompt, "first"}
    assert_receive {:provider, _, provider}
    {:ok, _} = Conversation.prompt(pid, "second")
    send(provider, {:events, [done("first answer")]})
    assert_receive {:hook, :stop}
    assert_receive {:agent_runtime, "test", %{type: :turn_completed}}
    assert_receive {:hook, :prompt, "second"}
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("second answer")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "package approval waits enforce allow and deny before backend invocation" do
    for decision <- [:approved, :denied] do
      {pid, _} = start(requires_approval: true)
      {:ok, _} = Conversation.prompt(pid, "approve")
      assert_receive {:provider, _, provider}
      send(provider, {:events, tool_response()})
      assert_receive {:agent_runtime, "test", %{type: :interaction_requested, interaction_id: id}}
      refute_receive {:tool, _, _}, 20
      :ok = Conversation.resolve(pid, id, decision)

      if decision == :approved do
        assert_receive {:tool, _, tool}
        send(tool, {:result, {:ok, %{text: "ok"}}})
      else
        refute_receive {:tool, _, _}, 20
      end

      assert_receive {:provider, _, provider}
      send(provider, {:events, [done("done")]})
      assert_receive {:agent_runtime, "test", %{type: :run_completed}}
    end
  end

  test "failed admission releases caller and prevents provider effects" do
    {:ok, table} = EphemeralStore.new(1)
    {pid, _} = start(store: GatedStore, context: %{table: table, test: self(), gate: :admit})
    caller = Task.async(fn -> Conversation.prompt(pid, "hello") end)
    assert_receive {:commit_waiting, worker}
    send(worker, :fail)
    assert {:error, _} = Task.await(caller)
    assert Conversation.status(pid).phase == :storage_failed
    refute_receive {:provider, _, _}, 20
  end

  test "cancel races a committed tool intent and never dispatches it" do
    {:ok, table} = EphemeralStore.new(1)

    {pid, _} =
      start(store: GatedStore, context: %{table: table, test: self(), gate: :tool_invoked})

    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:commit_waiting, worker}
    :ok = Conversation.cancel(pid)
    send(worker, :commit)
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled}}
    refute_receive {:tool, _, _}, 20
  end

  test "provider failure, missing terminal and duplicate tool ids terminate without tools" do
    for events <- [
          [%{type: :response_failed, error: "offline"}],
          [hd(tool_response()), hd(tool_response()), done("bad")]
        ] do
      {pid, _} = start()
      {:ok, _} = Conversation.prompt(pid, "hello")
      assert_receive {:provider, _, provider}
      send(provider, {:events, events})
      assert_receive {:agent_runtime, "test", %{type: :run_failed}}
      refute_receive {:tool, _, _}, 20
    end
  end

  test "finite work budget settles a run before provider continuation" do
    {pid, _} = start(work: 1)
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:agent_runtime, "test", %{type: :run_failed}}
    assert Conversation.status(pid).run.state == :failed
    refute_receive {:tool, _, _}, 20
  end

  test "restart is inspection only and retains budget, outstanding tool and transcript" do
    {pid, store} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:tool, _, _}
    {:ok, %{run: run}} = EphemeralStore.load(store, "test")
    GenServer.stop(pid)
    {restored, _} = start(run: run, context: store)
    assert Conversation.status(restored).phase == :recovery_required
    assert Conversation.status(restored).run == run
    assert run.execution_budget.used == 2
    assert map_size(run.active_tools) == 1
    assert {:error, _} = Conversation.prompt(restored, "do not replay")
    refute_receive {:tool, _, _}, 20
  end

  test "deadline cancels a provider blocked before yielding and stale chunks are rejected" do
    {pid, _} = start(run_timeout: 100)
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    monitor = Process.monitor(provider)

    assert {:error, _} =
             GenServer.call(
               pid,
               {:chunk, make_ref(), %{type: :content_text_delta, delta: "stale"}}
             )

    assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 500
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled, state: :unknown_outcome}}, 500
    refute_receive {:agent_runtime, "test", %{delta: "stale"}}, 20
  end

  test "terminal assistant tool blocks are authoritative even without tool completion deltas" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}

    message = %{
      role: :assistant,
      content: [%{type: :tool_call, id: "final_call", name: "read", arguments: %{"path" => "x"}}]
    }

    send(provider, {:events, [%{type: :response_completed, message: message}]})
    assert_receive {:tool, _, tool}
    send(tool, {:result, {:ok, %{text: "ok"}}})
    assert_receive {:provider, _, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
  end

  test "cancellation clears correlated interaction in the persisted terminal snapshot" do
    {pid, store} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:tool, _, tool}
    send(tool, :ask)
    assert_receive {:agent_runtime, "test", %{type: :interaction_requested}}
    :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled}}
    {:ok, %{run: run}} = EphemeralStore.load(store, "test")
    assert run.context.conversation.pending_interaction == nil
  end

  test "stop-hook continuation bypasses user prompt hooks and keeps host context" do
    {pid, _} = start(hooks: ContinueHooks)
    :sys.replace_state(pid, fn state -> put_in(state.run.context[:host_key], "keep") end)
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive :user_prompt_hook
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("first")]})
    assert_receive {:provider, %{messages: messages}, next}
    assert List.last(messages).content == "synthetic"
    refute_receive :user_prompt_hook, 20
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
    assert Conversation.status(pid).run.context.host_key == "keep"
  end

  test "a failed turn does not poison a successful follow-up outcome" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "first")
    assert_receive {:provider, _, provider}
    {:ok, _} = Conversation.follow_up(pid, "second")
    send(provider, {:events, [%{type: :response_failed, error: "offline"}]})
    assert_receive {:agent_runtime, "test", %{type: :turn_failed, error: "offline"}}
    assert_receive {:provider, _, next}
    send(next, {:events, [done("ok")]})
    assert_receive {:agent_runtime, "test", %{type: :run_completed, outcome: %{error: nil}}}
  end

  test "malformed terminal role is rejected before persisting an assistant response" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :user, content: "injected"}}]}
    )

    assert_receive {:agent_runtime, "test", %{type: :run_failed}}
    refute Enum.any?(Conversation.status(pid).messages, &(&1[:content] == "injected"))
  end

  test "stream exhaustion without terminal fails" do
    {pid, _} = start(provider: EndedProvider)
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:agent_runtime, "test", %{type: :run_failed}}
    assert Conversation.status(pid).run.state == :failed
  end

  @tag capture_log: true
  test "tool crash retains uncertainty and never continues the provider" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:tool, _, tool}
    send(tool, :crash)
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled, state: :unknown_outcome}}
    refute_receive {:provider, _, _}, 20
  end

  test "cancellation during package approval never invokes the backend" do
    {pid, _} = start(requires_approval: true)
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, tool_response()})
    assert_receive {:agent_runtime, "test", %{type: :interaction_requested, interaction_id: id}}
    :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled}}
    assert {:error, _} = Conversation.resolve(pid, id, :approved)
    refute_receive {:tool, _, _}, 20
  end

  test "expiry before completion commit follows deadline settlement, not storage failure" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}

    :sys.replace_state(pid, fn state ->
      put_in(state.run.deadline, System.system_time(:millisecond) - 1)
    end)

    send(provider, {:events, [done("too late")]})
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled, state: :unknown_outcome}}
    refute_receive {:agent_runtime, "test", %{type: :storage_failed}}, 20
  end

  test "cancellation racing a successful final commit publishes the committed terminal once" do
    {:ok, table} = EphemeralStore.new(1)
    {pid, _} = start(store: GatedStore, context: %{table: table, test: self(), gate: :finish})
    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("done")]})
    assert_receive {:commit_waiting, worker}
    :ok = Conversation.cancel(pid)
    send(worker, :commit)
    assert_receive {:agent_runtime, "test", %{type: :run_completed}}
    refute_receive {:agent_runtime, "test", %{type: :run_completed}}, 20
    refute_receive {:agent_runtime, "test", %{type: :run_cancelled}}, 20
    assert Conversation.status(pid).run.state == :completed
  end

  test "repeated cancellation during cleanup publishes its terminal once" do
    {:ok, table} = EphemeralStore.new(1)

    {pid, _} =
      start(store: GatedStore, context: %{table: table, test: self(), gate: :cleanup_settled})

    {:ok, _} = Conversation.prompt(pid, "hello")
    assert_receive {:provider, _, _}
    :ok = Conversation.cancel(pid)
    assert_receive {:commit_waiting, worker}
    :ok = Conversation.cancel(pid)
    send(worker, :commit)
    assert_receive {:agent_runtime, "test", %{type: :run_cancelled}}
    refute_receive {:agent_runtime, "test", %{type: :run_cancelled}}, 20
    assert Conversation.status(pid).phase == :terminal
  end
end
