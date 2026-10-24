defmodule Backplane.AgentRuntime.CodexCt07Test do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{Contract, Dynamic, DynamicRuntime}

  defmodule Backend do
    def execute(%{"value" => value}), do: {:ok, %{value: value}}
  end

  defmodule ErrorBackend do
    def execute(_arguments), do: {:error, Error.new(:execution_failure, "remote failed")}
  end

  defmodule ConversationBackend do
    def execute(%{arguments: %{"value" => value}}), do: {:ok, %{value: value}}
  end

  defmodule TcpMcpAdapter do
    def list_resources(%{"server" => server}, _operation),
      do: request(server, "resources/list", %{})

    def list_resource_templates(%{"server" => server}, _operation),
      do: request(server, "resources/templates/list", %{})

    def read_resource(%{"server" => server, "uri" => uri}, _operation),
      do: request(server, "resources/read", %{"uri" => uri})

    defp request(server, method, params) do
      [host, port] = String.split(server, ":", parts: 2)

      {:ok, socket} =
        :gen_tcp.connect(String.to_charlist(host), String.to_integer(port), [
          :binary,
          active: false
        ])

      payload =
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

      :ok = :gen_tcp.send(socket, payload <> "\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)

      %{"result" => result} = response |> String.trim() |> JSON.decode!()
      {:ok, result}
    end
  end

  defmodule LocalMcpServer do
    def start(parent) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)

      pid =
        spawn(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, payload} = :gen_tcp.recv(socket, 0, 2_000)
          request = payload |> String.trim() |> JSON.decode!()
          send(parent, {:mcp_request, request})

          response = %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "resources" => [%{"name" => "fixture", "uri" => "memory://fixture"}],
              "nextCursor" => nil
            }
          }

          :ok = :gen_tcp.send(socket, JSON.encode!(response) <> "\n")
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end)

      {pid, port}
    end
  end

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

  defp attrs(name, extra \\ %{}) do
    Map.merge(
      %{
        namespace: "mcp",
        name: name,
        description: "dynamic tool",
        backend: Backend,
        schema: %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}},
        safety: %{read_only: true, retry_safe: true, parallel_safe: true}
      },
      extra
    )
  end

  test "search is owner scoped and discovery does not grant" do
    assert {:ok, state} = Dynamic.new(max_results: 5)

    assert {:ok, state, [%{status: :discovered}]} =
             Dynamic.discover(state, "run-a", [attrs("echo")])

    assert {:ok, []} = Dynamic.search(state, "run-b", "echo")
    assert {:ok, [%{status: :discovered}]} = Dynamic.search(state, "run-a", "echo")
  end

  test "malformed schemas fail strict discovery and collisions are fenced" do
    assert {:ok, state} = Dynamic.new()

    assert {:error, %Error{class: :unsupported_capability}} =
             Dynamic.discover(state, "run-a", [
               attrs("bad", %{schema: %{"type" => "object", "$schema" => "https://bad"}})
             ])

    assert {:ok, state, _} = Dynamic.discover(state, "run-a", [attrs("echo")])

    assert {:error, %Error{class: :validation}} =
             Dynamic.discover(state, "run-b", [attrs("echo")])
  end

  test "publication, snapshot call, removal, and stale snapshot are fenced" do
    assert {:ok, state} = Dynamic.new()
    assert {:ok, state, _} = Dynamic.discover(state, "run-a", [attrs("echo")])
    assert {:ok, state, %{revision: 1}} = Dynamic.publish(state, "run-a", "mcp::echo")
    assert {:ok, state, snapshot} = Dynamic.snapshot(state, "run-a")

    assert {:ok, _state, %{value: "ok"}} =
             Dynamic.call(state, snapshot, "run-a", "mcp::echo", %{"value" => "ok"})

    assert {:error, %Error{class: :forbidden}} =
             Dynamic.call(state, snapshot, "run-b", "mcp::echo", %{"value" => "ok"})

    assert {:ok, state} = Dynamic.revoke(state, "run-a", "mcp::echo")

    assert {:error, %Error{class: :resource_conflict}} =
             Dynamic.call(state, snapshot, "run-a", "mcp::echo", %{"value" => "ok"})
  end

  test "bounded search and plugin receipts do not install tools" do
    assert {:ok, state} = Dynamic.new(max_results: 1)

    assert {:error, %Error{class: :budget_exceeded}} =
             Dynamic.discover(state, "run-a", [attrs("one"), attrs("two")])

    assert {:ok, state, receipt} = Dynamic.request_plugin(state, "run-a", %{package: "demo"})
    assert receipt.status == :requested

    assert {:ok, state, completed} =
             Dynamic.complete_plugin(state, "run-a", %{id: receipt.id, status: :installed})

    assert completed.status == :completed
    assert {:ok, []} = Dynamic.search(state, "run-a", "demo")
  end

  test "published definitions without an adapter report unsupported capability" do
    assert {:ok, state} = Dynamic.new()
    assert {:ok, state, _} = Dynamic.discover(state, "run-a", [attrs("remote", %{backend: nil})])

    assert {:error, %Error{class: :unsupported_capability}} =
             Dynamic.publish(state, "run-a", "mcp::remote")

    assert {:ok, _snapshot_state, snapshot} = Dynamic.snapshot(state, "run-a")
    assert snapshot.names == %{}
  end

  test "backend errors are propagated instead of wrapped as successful results" do
    assert {:ok, state} = Dynamic.new()

    assert {:ok, state, _} =
             Dynamic.discover(state, "run-a", [attrs("failure", %{backend: ErrorBackend})])

    assert {:ok, state, _} = Dynamic.publish(state, "run-a", "mcp::failure")
    assert {:ok, _state, snapshot} = Dynamic.snapshot(state, "run-a")

    assert {:error, %Error{class: :execution_failure, message: "remote failed"}} =
             Dynamic.call(state, snapshot, "run-a", "mcp::failure", %{})
  end

  test "one public runtime accepts overlapping candidates for successive independent owners" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")]})

    for {caller, run_id, incarnation} <- [
          {"host", "first-run", 1},
          {"host", "second-run", 1},
          {"other", "first-run", 1},
          {"host", "first-run", 2}
        ] do
      assert {:ok, %{tools: [], publication: %{status: :no_matches}}} =
               DynamicRuntime.call(%{
                 tool_name: "tool_search",
                 arguments: %{"query" => "unmatched"},
                 caller: caller,
                 run_id: run_id,
                 incarnation: incarnation,
                 backend_context: %{runtime: runtime}
               })
    end
  end

  defp search_operation(runtime, extra \\ %{}) do
    Map.merge(
      %{
        tool_name: "tool_search",
        arguments: %{"query" => "echo"},
        caller: "host",
        run_id: "owner-run",
        incarnation: 1,
        backend_context: %{
          runtime: runtime,
          stage_catalog: fn update ->
            {:ok, %{status: :staged, revision: update.catalog.revision}}
          end,
          catalog_snapshot: %{
            revision: 1,
            registry: %Backplane.AgentRuntime.ToolRegistry{},
            authority: %{caller: "host", run_id: "owner-run", grants: [], tool_revisions: %{}},
            tools: []
          }
        }
      },
      extra
    )
  end

  test "metadata search finds description-only credentials" do
    runtime =
      start_supervised!(
        {DynamicRuntime, candidates: [attrs("vault", %{description: "Read credentials"})]}
      )

    base = search_operation(runtime, %{arguments: %{"query" => "credential"}})
    assert {:ok, %{tools: [%{name: "mcp::vault"}]}} = DynamicRuntime.call(base)
  end

  for {label, schema, query} <- [
        {"atom property names", %{type: "object", properties: %{secret_key: %{type: "string"}}},
         "secret_key"},
        {"boolean property schemas",
         %{"type" => "object", "properties" => %{"allowed" => true, "blocked" => false}},
         "allowed blocked"},
        {"boolean item schemas",
         %{
           "type" => "object",
           "properties" => %{"entries" => %{"type" => "array", "items" => false}}
         }, "entries"},
        {"boolean anyOf schemas",
         %{
           "type" => "object",
           "properties" => %{"choice" => %{"anyOf" => [true, false]}}
         }, "choice"}
      ] do
    @search_schema schema
    @search_query query
    test "metadata search preserves strict admission of #{label}" do
      candidate = attrs("inspect", %{schema: @search_schema})
      assert {:ok, contract} = Contract.new(candidate)

      assert {:ok, %{accepted: ["mcp::inspect"], rejected: []}} =
               ToolCatalog.admit_batch([Contract.descriptor(contract)],
                 mode: :strict,
                 authority: %{
                   caller: "host",
                   run_id: "owner-run",
                   grants: ["mcp::inspect"],
                   tool_revisions: %{"mcp::inspect" => 1}
                 }
               )

      runtime = start_supervised!({DynamicRuntime, candidates: [candidate]})

      assert {:ok, %{tools: [%{name: "mcp::inspect"}], publication: %{status: :staged}}} =
               DynamicRuntime.call(
                 search_operation(runtime, %{arguments: %{"query" => @search_query}})
               )
    end
  end

  test "empty metadata search queries fail validation" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")]})

    assert {:error, %Error{class: :validation}} =
             DynamicRuntime.call(search_operation(runtime, %{arguments: %{"query" => ""}}))
  end

  test "malformed queries and limits fail without crashing the runtime" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")], max_results: 1})
    base = search_operation(runtime)

    for arguments <- [
          nil,
          [],
          42,
          %{},
          %{"query" => nil},
          %{"query" => 42},
          %{"query" => <<255>>},
          %{"query" => "  "},
          %{"query" => "echo"},
          %{"query" => "echo", "limit" => nil},
          %{"query" => "echo", "limit" => 0},
          %{"query" => "echo", "limit" => 2},
          %{"query" => "echo", "limit" => "1"},
          %{"query" => "echo", "limit" => 1.0}
        ] do
      assert {:error, %Error{class: :validation}} =
               DynamicRuntime.call(%{base | arguments: arguments})

      assert Process.alive?(runtime)
    end

    assert {:ok, %{tools: [], publication: %{status: :no_matches}}} =
             DynamicRuntime.call(%{base | arguments: %{"query" => "the and is", "limit" => 1}})

    assert {:ok, %{tools: [_]}} =
             DynamicRuntime.call(%{base | arguments: %{"query" => "echo", "limit" => 1}})
  end

  test "publication consumes only the current caller run and incarnation" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")]})
    base = search_operation(runtime)

    for operation <- [
          base,
          %{base | caller: "other"},
          %{base | run_id: "other-run"},
          %{base | incarnation: 2},
          Map.delete(base, :caller)
        ] do
      assert {:ok, %{tools: [%{name: "mcp::echo"}], publication: %{status: :staged}}} =
               DynamicRuntime.call(operation)

      assert {:ok, %{tools: [], publication: %{status: :no_matches}}} =
               DynamicRuntime.call(operation)
    end
  end

  test "invalid owner identities fail without changing candidate state" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")]})
    base = search_operation(runtime)

    for extra <- [
          %{caller: nil},
          %{caller: ""},
          %{caller: 1},
          %{run_id: nil},
          %{run_id: ""},
          %{run_id: 1},
          %{incarnation: 0},
          %{incarnation: nil},
          %{incarnation: "1"}
        ] do
      assert {:error, %Error{class: :validation}} = DynamicRuntime.call(Map.merge(base, extra))
      assert Process.alive?(runtime)
    end

    assert {:ok, %{tools: [_]}} = DynamicRuntime.call(base)
  end

  test "failed staging preserves the previous owner partition" do
    runtime = start_supervised!({DynamicRuntime, candidates: [attrs("echo")]})
    base = search_operation(runtime)

    assert {:ok, %{tools: []}} =
             DynamicRuntime.call(%{base | arguments: %{"query" => "unmatched"}})

    rejected =
      put_in(
        base.backend_context.stage_catalog,
        fn _ -> {:error, Error.new(:resource_conflict, "stale producer")} end
      )

    assert {:error, %Error{class: :resource_conflict}} = DynamicRuntime.call(rejected)
    assert {:ok, %{tools: [_]}} = DynamicRuntime.call(base)
  end

  test "within owner duplicates and active catalog collisions stay fenced" do
    duplicate = start_supervised!({DynamicRuntime, candidates: [attrs("echo"), attrs("echo")]})
    assert {:error, %Error{class: :validation}} = DynamicRuntime.call(search_operation(duplicate))

    {:ok, runtime} = DynamicRuntime.start_link(candidates: [attrs("echo")])
    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    base = search_operation(runtime)
    {:ok, contract} = Backplane.AgentRuntime.Codex.Contract.new(attrs("echo"))

    {:ok, registry} =
      Backplane.AgentRuntime.ToolRegistry.register(
        base.backend_context.catalog_snapshot.registry,
        Backplane.AgentRuntime.Codex.Contract.descriptor(contract)
      )

    collision = put_in(base.backend_context.catalog_snapshot.registry, registry)
    assert {:error, %Error{class: :resource_conflict}} = DynamicRuntime.call(collision)
    assert {:ok, %{tools: [_]}} = DynamicRuntime.call(base)
  end

  test "tool search publishes through Conversation for the next provider turn" do
    candidate = attrs("echo", %{backend: ConversationBackend})
    runtime = start_supervised!({DynamicRuntime, candidates: [candidate]})

    for run_id <- ["dynamic-run", "dynamic-second-run"] do
      authority = %{
        caller: "host",
        run_id: run_id,
        grants: ["tool_search"],
        tool_revisions: %{"tool_search" => 1}
      }

      assert {:ok, profile} =
               Codex.profile(:dynamic, %{dynamic_runtime: runtime}, authority,
                 tools: ["tool_search"]
               )

      {:ok, store} = EphemeralStore.new(1)

      {:ok, conversation} =
        Conversation.start_link(
          run_id: run_id,
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: profile.registry,
          tools: profile.tools,
          authority: profile.authority,
          schema_admission: :strict,
          work: 12,
          run_timeout: 5_000
        )

      assert {:ok, _} = Conversation.prompt(conversation, "discover echo")
      assert_receive {:provider, %{tools: [%{name: "tool_search"}]}, search_provider}

      send(search_provider, {
        :events,
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "search-1",
              name: "tool_search",
              arguments: %{"query" => "echo"}
            }
          },
          %{type: :response_completed, message: %{role: :assistant, content: "searching"}}
        ]
      })

      assert_receive {:agent_runtime, ^run_id, %{type: :tool_completed}}

      assert_receive {:provider, %{catalog_revision: revision, tools: tools, messages: messages},
                      echo_provider}

      assert %{is_error: false, publication: %{status: :staged}} = List.last(messages).result
      assert revision == 2
      assert Enum.any?(tools, &(&1.name == "mcp::echo"))

      send(echo_provider, {
        :events,
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "echo-1",
              name: "mcp::echo",
              arguments: %{"value" => "published"}
            }
          },
          %{type: :response_completed, message: %{role: :assistant, content: "calling"}}
        ]
      })

      assert_receive {:agent_runtime, ^run_id, %{type: :tool_completed}}
      assert_receive {:provider, %{messages: messages}, done_provider}
      assert %{is_error: false, value: "published"} = List.last(messages).result

      send(done_provider, {
        :events,
        [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
      })

      assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}
    end
  end

  test "MCP resources cross a real local JSON-RPC boundary through Conversation" do
    {server, port} = LocalMcpServer.start(self())
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)
    runtime = start_supervised!({DynamicRuntime, mcp_adapter: TcpMcpAdapter})

    authority = %{
      caller: "host",
      run_id: "mcp-run",
      grants: ["list_mcp_resources"],
      tool_revisions: %{"list_mcp_resources" => 1}
    }

    assert {:ok, profile} =
             Codex.profile(:dynamic, %{dynamic_runtime: runtime}, authority,
               tools: ["list_mcp_resources"]
             )

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "mcp-run",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 8,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "list resources")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "mcp-list",
            name: "list_mcp_resources",
            arguments: %{"server" => "127.0.0.1:#{port}"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "listing"}}
      ]
    })

    assert_receive {:mcp_request, request}, 5_000
    assert %{"method" => "resources/list", "params" => %{}} = request
    assert_receive {:provider, %{messages: messages}, final_provider}, 5_000

    assert %{result: %{:is_error => false, "resources" => [%{"uri" => "memory://fixture"}]}} =
             List.last(messages)

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "mcp-run", %{type: :run_completed}}
  end

  test "a discovered tool remains fenced from another call in the same provider batch" do
    candidate = attrs("echo", %{backend: ConversationBackend})
    runtime = start_supervised!({DynamicRuntime, candidates: [candidate]})

    authority = %{
      caller: "host",
      run_id: "fenced-run",
      grants: ["tool_search"],
      tool_revisions: %{"tool_search" => 1}
    }

    assert {:ok, profile} = Codex.profile(:dynamic, %{dynamic_runtime: runtime}, authority)
    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "fenced-run",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "discover and call")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "search", name: "tool_search", arguments: %{"query" => "echo"}}
        },
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "premature",
            name: "mcp::echo",
            arguments: %{"value" => "must-not-run"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "batch"}}
      ]
    })

    assert_receive {:provider, %{catalog_revision: 2, messages: messages}, final_provider}, 5_000
    assert %{name: "mcp::echo", result: %{is_error: true}} = List.last(messages)

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "fenced-run", %{type: :run_completed}}
  end
end
