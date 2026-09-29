defmodule Backplane.AgentRuntime.CodexCt08Test do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}

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

  defmodule EchoBackend do
    def execute(%{arguments: %{"value" => value}}), do: {:ok, %{value: value}}
  end

  setup do
    {:ok, registry} = ResourceRegistry.start_link([])
    %{registry: registry}
  end

  defp opts(dispatcher, extra \\ []) do
    [
      dispatcher: dispatcher,
      execution_context: %{run_id: "run-a", grants: ["mcp::echo"], catalog_revision: 4},
      timeout: 3_000
    ] ++ extra
  end

  test "executes real JavaScript and re-enters the host callback twice", %{registry: registry} do
    parent = self()

    dispatcher = fn request, context ->
      send(parent, {:tool, request, context})
      {:ok, %{value: request.arguments["value"]}, context}
    end

    code = """
    const first = await codex.tool("mcp::echo", {value: 2});
    const second = await codex.tool("mcp::echo", {value: 3});
    return first.value + second.value;
    """

    assert {:ok, %{status: :completed, value: 5}} =
             CodeMode.execute(registry, "run-a", code, opts(dispatcher))

    assert_receive {:tool, %{tool_name: "mcp::echo", input_kind: :function}, %{run_id: "run-a"}}
    assert_receive {:tool, %{tool_name: "mcp::echo", input_kind: :function}, %{run_id: "run-a"}}
  end

  test "yielded continuations resume and are owner fenced", %{registry: registry} do
    dispatcher = fn _request, context -> {:ok, %{value: 7}, context} end

    assert {:ok, %{status: :yielded, handle: handle, value: "checkpoint"}} =
             CodeMode.execute(
               registry,
               "run-a",
               "const answer = yield \"checkpoint\"; return answer + 1;",
               opts(dispatcher)
             )

    assert {:error, %Error{class: :forbidden}} =
             CodeMode.resume(registry, handle, 4, owner: "run-b")

    assert {:ok, %{status: :completed, value: 5}} =
             CodeMode.resume(registry, handle, 4, owner: "run-a")

    assert {:error, %Error{class: :not_found}} =
             CodeMode.resume(registry, handle, 4, owner: "run-a")
  end

  test "nested permission errors propagate and JavaScript cannot use network or filesystem", %{
    registry: registry
  } do
    denied = fn _request, _context -> {:error, Error.new(:forbidden, "tool is not granted")} end

    assert {:error, %Error{class: :execution_failure}} =
             CodeMode.execute(
               registry,
               "run-a",
               "await codex.tool(\"secret::read\", {});",
               opts(denied)
             )

    assert {:error, %Error{class: :execution_failure}} =
             CodeMode.execute(
               registry,
               "run-a",
               "await fetch(\"https://example.invalid\");",
               opts(denied)
             )
  end

  test "requires an admitted dispatcher and rejects an unbound context", %{registry: registry} do
    assert {:error, %Error{class: :unsupported_capability}} =
             CodeMode.execute(registry, "run-a", "return 1;",
               execution_context: %{run_id: "run-a"}
             )

    assert {:error, %Error{class: :forbidden}} =
             CodeMode.execute(registry, "run-a", "return 1;",
               dispatcher: fn _, _ -> {:ok, :unused} end,
               execution_context: %{run_id: "run-b"}
             )
  end

  test "owner death terminates the Code Mode worker and active nested dispatch", %{
    registry: registry
  } do
    parent = self()

    dispatcher = fn _request, context ->
      send(parent, {:nested_dispatch_started, self()})

      receive do
        :release -> {:ok, %{released: true}, context}
      end
    end

    owner =
      spawn(fn ->
        CodeMode.execute(
          registry,
          "run-a",
          "await codex.tool(\"mcp::echo\", {value: 1}); return 1;",
          opts(dispatcher, timeout: 30_000)
        )
      end)

    assert_receive {:nested_dispatch_started, nested}, 5_000
    on_exit(fn -> if Process.alive?(nested), do: send(nested, :release) end)

    nested_monitor = Process.monitor(nested)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^nested_monitor, :process, ^nested, _reason}, 1_000
  end

  test "Code Mode rejects completed values beyond the configured output bound", %{
    registry: registry
  } do
    dispatcher = fn _request, context -> {:ok, %{}, context} end

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(
               registry,
               "run-a",
               "return 'x'.repeat(1024);",
               opts(dispatcher, output_limit: 64)
             )
  end

  test "Code Mode enforces source, continuation, yield, tool-count, and time bounds", %{
    registry: registry
  } do
    dispatcher = fn _request, context -> {:ok, %{}, context} end

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(
               registry,
               "run-a",
               "return 1;",
               opts(dispatcher, code_limit: 4)
             )

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(
               registry,
               "run-a",
               "yield 'x'.repeat(1024);",
               opts(dispatcher, output_limit: 64)
             )

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(
               registry,
               "run-a",
               "const value = yield 1; return value;",
               opts(dispatcher, output_limit: 64)
             )

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.resume(registry, handle, String.duplicate("x", 1024), owner: "run-a")

    assert {:ok, %{status: :completed, value: 2}} =
             CodeMode.resume(registry, handle, 2, owner: "run-a")

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(
               registry,
               "run-a",
               "await codex.tool('mcp::echo', {}); await codex.tool('mcp::echo', {});",
               opts(dispatcher, tool_limit: 1)
             )

    assert {:error, %Error{class: :timeout}} =
             CodeMode.execute(
               registry,
               "run-a",
               "await new Promise(() => {});",
               opts(dispatcher, timeout: 25)
             )
  end

  test "Code Mode rejects concurrent nested calls before dispatching a second mutation", %{
    registry: registry
  } do
    parent = self()

    dispatcher = fn request, context ->
      send(parent, {:nested_mutation, request.tool_name})
      Process.sleep(50)
      {:ok, %{}, context}
    end

    assert {:error, %Error{class: :execution_failure}} =
             CodeMode.execute(
               registry,
               "run-a",
               "await Promise.all([codex.tool('state::write', {value: 1}), codex.tool('state::write', {value: 2})]);",
               opts(dispatcher)
             )

    assert_receive {:nested_mutation, "state::write"}
    refute_receive {:nested_mutation, "state::write"}, 100
  end

  test "Code Mode-only profile hides nested targets and dispatches them through Conversation", %{
    registry: resource_registry
  } do
    target = %{
      namespace: "mcp",
      name: "echo",
      description: "Echo a value.",
      schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"],
        "additionalProperties" => false
      },
      backend: EchoBackend,
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    context = %{resource_registry: resource_registry, code_mode_contracts: [target]}

    authority = %{
      caller: "host",
      run_id: "code-mode-run",
      grants: ["exec", "wait", "mcp::echo"],
      tool_revisions: %{"exec" => 1, "wait" => 1, "mcp::echo" => 1}
    }

    assert {:ok, profile} = Codex.profile(:code_mode_only, context, authority)
    assert Enum.map(profile.tools, & &1.name) == ["exec", "wait"]
    assert Map.has_key?(profile.registry.tools, "mcp::echo")

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "code-mode-run",
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

    assert {:ok, _} = Conversation.prompt(conversation, "run code")
    assert_receive {:provider, %{tools: provider_tools}, exec_provider}
    assert Enum.map(provider_tools, & &1.name) == ["exec", "wait"]

    code = "const result = await codex.tool(\"mcp::echo\", {value: 6}); return result.value;"

    send(exec_provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "exec-1", name: "exec", arguments: code}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "running"}}
      ]
    })

    assert_receive {:agent_runtime, "code-mode-run", %{type: :tool_completed}}, 5_000
    assert_receive {:provider, %{messages: messages}, final_provider}, 5_000
    assert %{is_error: false, status: :completed, value: 6} = List.last(messages).result

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "code-mode-run", %{type: :run_completed}}
  end
end
