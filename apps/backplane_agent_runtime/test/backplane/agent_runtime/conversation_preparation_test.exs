defmodule Backplane.AgentRuntime.ConversationPreparationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Hooks do
    def prepare_tool(invocation, context) do
      send(context.test, {:prepare, invocation, context, self()})

      receive do
        {:decision, result} ->
          result

        :crash ->
          raise "preparation crashed"

        :escape_interaction ->
          spawn(fn ->
            send(context.test, {:escaped_answer, context.interact.(%{kind: :prepare})})
          end)

          receive do: ({:decision, result} -> result)

        :ask ->
          result = context.interact.(%{kind: :prepare, operation: invocation})
          send(context.test, {:prepare_answer, result})
          receive do: ({:decision, result} -> result)
      end
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:backend, operation, self()})

      receive do
        :finish ->
          {:ok, %{text: "done"}}

        {:escaped_nested, name, input} ->
          spawn(fn ->
            result =
              operation.backend_context.nested_dispatch.(%{tool_name: name, arguments: input})

            send(operation.backend_context.test, {:escaped_nested_result, result})
          end)

          receive do: (:finish -> {:ok, %{text: "escaped outer done"}})

        {:nested, name, input} ->
          result =
            operation.backend_context.nested_dispatch.(%{tool_name: name, arguments: input})

          send(operation.backend_context.test, {:nested_result, result})
          {:ok, %{text: "outer done"}}
      end
    end
  end

  defmodule Store do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :tool_invoked do
        send(context.test, {:intent, elem(meta.command, 2), self()})
        if context.gate, do: receive(do: (:commit -> :ok))
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  for custom? <- [false, true] do
    test "#{if custom?, do: "raw custom", else: "function"} input B is approved, committed and dispatched exactly" do
      custom? = unquote(custom?)
      {pid, _} = start(custom: custom?, approval: true, gate: true)
      original = if custom?, do: "original patch", else: %{"path" => "A"}
      final = if custom?, do: "final patch\n", else: %{"path" => "B"}
      {invocation, hook} = begin_tool(pid, "read", original)
      assert invocation.arguments == original
      refute_receive {:intent, _, _}, 10
      send(hook, {:decision, {:allow, final}})

      assert_receive {:agent_runtime, "prepare",
                      %{
                        type: :interaction_requested,
                        interaction_id: id,
                        request: %{operation: approved}
                      }},
                     1_000

      assert approved.arguments == final
      assert approved.invocation_id == invocation.invocation_id
      assert :ok = Conversation.resolve(pid, id, :approved)
      assert_receive {:intent, committed, store}, 1_000
      assert Map.take(committed, Map.keys(approved)) == approved
      refute_receive {:backend, _, _}, 10
      send(store, :commit)
      assert_receive {:backend, operation, backend}, 1_000
      assert operation.arguments == final
      assert operation.tool_name == "read"
      assert operation.invocation_id == invocation.invocation_id
      send(backend, :finish)
    end
  end

  test "approval input edits demand a fresh approval and run preparation only once" do
    {pid, _} = start(approval: true)
    {_, hook} = begin_tool(pid)
    send(hook, {:decision, :allow})

    assert_receive {:agent_runtime, "prepare",
                    %{type: :interaction_requested, interaction_id: first}},
                   1_000

    assert :ok = Conversation.resolve(pid, first, {:update_input, %{"path" => "B"}})

    assert_receive {:agent_runtime, "prepare",
                    %{
                      type: :interaction_requested,
                      interaction_id: second,
                      request: %{operation: %{arguments: %{"path" => "B"}}}
                    }},
                   1_000

    assert first != second
    assert {:error, %Error{class: :not_found}} = Conversation.resolve(pid, first, :approved)
    refute_receive {:intent, _, _}, 10
    refute_receive {:prepare, _, _, _}, 10
    assert :ok = Conversation.resolve(pid, second, :approved)
    assert_receive {:backend, %{arguments: %{"path" => "B"}}, backend}, 1_000
    send(backend, :finish)
  end

  test "approval edits cannot replenish active admission budget on an infinite run" do
    {pid, _} = start(approval: true, run_timeout: :infinity)
    {_, hook} = begin_tool(pid)
    send(hook, {:decision, :allow})

    assert_receive {:agent_runtime, "prepare",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    # Exhaust the remaining active budget while the human wait itself stays paused.
    :sys.replace_state(pid, &%{&1 | paused_admission_remaining: 0})
    assert :ok = Conversation.resolve(pid, id, {:update_input, %{"path" => "B"}})
    assert_receive {:agent_runtime, "prepare", %{type: :run_cancelled}}, 1_000
    refute_receive {:intent, _, _}, 10
    refute_receive {:backend, _, _}, 10
  end

  test "invalid approval edits never create another approval or intent" do
    {pid, _} = start(approval: true)
    {_, hook} = begin_tool(pid)
    send(hook, {:decision, :allow})

    assert_receive {:agent_runtime, "prepare",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    assert :ok = Conversation.resolve(pid, id, {:update_input, %{"path" => 42}})
    assert_receive {:provider, request, _}, 1_000
    assert List.last(request.messages).result.is_error
    refute_receive {:intent, _, _}, 10
    refute_receive {:agent_runtime, "prepare", %{type: :interaction_requested}}, 10
  end

  test "denial, hook errors, invalid inputs and invocation-shaped replies never dispatch" do
    for result <- [
          {:deny, "host policy"},
          {:error, Error.new(:forbidden, "host policy")},
          {:allow, %{"path" => 42}},
          {:ok, %{tool_name: "other", arguments: %{"path" => "B"}}}
        ] do
      {pid, _} = start()
      {_, hook} = begin_tool(pid)
      send(hook, {:decision, result})
      assert_receive {:provider, request, _}, 1_000
      assert List.last(request.messages).result.is_error
      refute_receive {:intent, _, _}, 10
      refute_receive {:backend, _, _}, 10
    end
  end

  test "preparation can repair initially invalid function input before final validation" do
    {pid, _} = start()
    {invocation, hook} = begin_tool(pid, "read", %{"path" => 42})
    assert invocation.arguments == %{"path" => 42}
    send(hook, {:decision, {:allow, %{"path" => "valid"}}})
    assert_receive {:backend, %{arguments: %{"path" => "valid"}}, backend}, 1_000
    send(backend, :finish)
  end

  test "custom transformed input must remain a binary" do
    {pid, _} = start(custom: true)
    {_, hook} = begin_tool(pid, "read", "raw")
    send(hook, {:decision, {:allow, %{"path" => "wrong type"}}})
    assert_receive {:provider, request, _}, 1_000
    assert List.last(request.messages).result.is_error
    refute_receive {:intent, _, _}, 10
  end

  test "a hook cannot complete while an escaped interaction still waits" do
    {pid, _} = start()
    {_, hook} = begin_tool(pid)
    send(hook, :escape_interaction)
    assert_receive {:agent_runtime, "prepare", %{type: :interaction_requested}}, 1_000
    send(hook, {:decision, :allow})
    assert_receive {:agent_runtime, "prepare", %{type: :run_cancelled}}, 1_000
    assert_receive {:escaped_answer, {:error, %Error{class: :cancelled}}}, 1_000
    refute_receive {:intent, _, _}, 10
    refute_receive {:backend, _, _}, 10
  end

  test "transformed inputs do not bypass the pinned tool authority" do
    {pid, _} = start(grants: [])
    {_, hook} = begin_tool(pid)
    send(hook, {:decision, {:allow, %{"path" => "B"}}})
    assert_receive {:provider, request, _}, 1_000
    assert List.last(request.messages).result.is_error
    refute_receive {:intent, _, _}, 10
  end

  test "preparation crash is a pre-invocation failure and permits provider continuation" do
    ExUnit.CaptureLog.capture_log(fn ->
      {pid, _} = start()
      {_, hook} = begin_tool(pid)
      send(hook, :crash)
      assert_receive {:provider, request, _}, 1_000
      assert List.last(request.messages).result.is_error
      assert map_size(Conversation.status(pid).run.active_tools) == 0
      refute_receive {:intent, _, _}, 10
    end)
  end

  test "cancellation fences preparation result and captured interaction callback" do
    {pid, _} = start()
    {_, _hook} = begin_tool(pid)
    state = :sys.get_state(pid)
    token = state.preparation.token
    assert :ok = Conversation.cancel(pid)
    send(pid, {state.preparation.task.ref, {:allow, %{"path" => "late"}}})

    assert {:error, %Error{class: :resource_conflict}} =
             GenServer.call(pid, {:interact, token, %{kind: :late}})

    refute_receive {:intent, _, _}, 10
    refute_receive {:backend, _, _}, 10
  end

  test "preparation interaction suspends deadlines and stale timer generations cannot dispatch" do
    {pid, _} = start(effect_timeout: 500)
    {_, hook} = begin_tool(pid)
    old = :sys.get_state(pid).preparation
    send(hook, :ask)

    assert_receive {:agent_runtime, "prepare",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    send(pid, {:timeout, old.task.ref, old.timer_generation})
    assert Conversation.status(pid).phase == :waiting_interaction
    assert :ok = Conversation.resolve(pid, id, :continue)
    assert_receive {:prepare_answer, {:ok, :continue}}, 1_000
    active = :sys.get_state(pid).preparation
    assert active.timer_generation != old.timer_generation
    send(pid, {:timeout, old.task.ref, old.timer_generation})
    send(hook, {:decision, :allow})
    assert_receive {:backend, _, backend}, 1_000
    send(backend, :finish)
  end

  test "current preparation deadline and late results create no invocation" do
    {pid, _} = start()
    begin_tool(pid)
    entry = :sys.get_state(pid).preparation
    send(pid, {:timeout, entry.task.ref, entry.timer_generation})
    send(pid, {entry.task.ref, :allow})
    assert_receive {:agent_runtime, "prepare", %{type: :run_cancelled}}, 1_000
    refute_receive {:intent, _, _}, 10
    refute_receive {:backend, _, _}, 10
  end

  test "nested transformation preserves outer effect and commits only final nested input" do
    {pid, _} = start()
    {_, hook} = begin_tool(pid, "outer")
    send(hook, {:decision, :allow})
    assert_receive {:backend, %{tool_name: "outer"}, outer}, 1_000
    outer_effect = :sys.get_state(pid).effect
    send(outer, {:nested, "read", %{"path" => "A"}})

    assert_receive {:prepare, %{tool_name: "read"} = nested_invocation, nested_context,
                    nested_hook},
                   1_000

    assert nested_context.catalog_snapshot.revision == nested_invocation.catalog_revision
    assert nested_context.catalog_snapshot.registry.tools["read"].backend == Backend
    assert :sys.get_state(pid).effect == outer_effect
    send(nested_hook, {:decision, {:allow, %{"path" => "B"}}})
    assert_receive {:intent, %{tool_name: "read", arguments: %{"path" => "B"}}, _}, 1_000
    assert_receive {:backend, %{tool_name: "read", arguments: %{"path" => "B"}}, nested}, 1_000
    send(nested, :finish)
    assert_receive {:nested_result, {:ok, %{text: "done"}}}, 1_000
  end

  test "an escaped nested preparation cannot outlive its enclosing tool" do
    {pid, _} = start()
    {_, hook} = begin_tool(pid, "outer")
    send(hook, {:decision, :allow})
    assert_receive {:backend, %{tool_name: "outer"}, outer}, 1_000
    send(outer, {:escaped_nested, "read", %{"path" => "A"}})
    assert_receive {:prepare, %{tool_name: "read"}, _, nested_hook}, 1_000
    entry = :sys.get_state(pid).preparation
    monitor = Process.monitor(nested_hook)
    send(outer, :finish)
    assert_receive {:escaped_nested_result, {:error, %Error{class: :cancelled}}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^nested_hook, _}, 1_000

    assert_receive {:agent_runtime, "prepare", %{type: :run_cancelled, state: :unknown_outcome}},
                   1_000

    send(pid, {entry.task.ref, :allow})
    refute_receive {:backend, %{tool_name: "read"}, _}, 10
    assert :sys.get_state(pid).preparation == nil
  end

  test "nested tools retain their approval restriction and preparation cancellation fence" do
    {pid, _} = start(approval: true)
    {_, hook} = begin_tool(pid, "outer")
    send(hook, {:decision, :allow})
    assert_receive {:backend, %{tool_name: "outer"}, outer}, 1_000
    send(outer, {:nested, "read", %{"path" => "A"}})
    assert_receive {:nested_result, {:error, %Error{class: :approval_required}}}, 1_000
    refute_receive {:prepare, %{tool_name: "read"}, _, _}, 10

    {pid, _} = start()
    {_, hook} = begin_tool(pid, "outer")
    send(hook, {:decision, :allow})
    assert_receive {:backend, %{tool_name: "outer"}, outer}, 1_000
    send(outer, {:nested, "read", %{"path" => "A"}})
    assert_receive {:prepare, %{tool_name: "read"}, _, _}, 1_000
    entry = :sys.get_state(pid).preparation
    assert :ok = Conversation.cancel(pid)
    send(pid, {entry.task.ref, :allow})
    refute_receive {:backend, %{tool_name: "read"}, _}, 10
  end

  defp begin_tool(pid, name \\ "read", input \\ %{"path" => "A"}) do
    assert {:ok, _} = Conversation.prompt(pid, "go")
    assert_receive {:provider, %{messages: [%{content: "go"}]}, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: "call", name: name, arguments: input}},
         %{type: :response_completed, message: %{role: :assistant, content: "tool"}}
       ]}
    )

    assert_receive {:prepare, invocation, context, hook}, 1_000
    assert context.catalog_snapshot.revision == invocation.catalog_revision
    assert context.catalog_snapshot.registry.tools[invocation.tool_name].backend == Backend
    refute Map.has_key?(context, :provider_emit)
    refute Map.has_key?(context, :nested_dispatch)
    refute Map.has_key?(context, :stage_catalog)
    {invocation, hook}
  end

  defp start(opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)

    registry =
      Enum.reduce(["read", "outer"], %ToolRegistry{}, fn name, registry ->
        {:ok, registry} =
          ToolRegistry.register(registry, %{
            tool_name: name,
            tool_revision: 1,
            codex_input_kind: if(opts[:custom] && name == "read", do: :custom, else: :function),
            schema: %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"],
              "additionalProperties" => false
            },
            safety: %{
              read_only: true,
              retry_safe: true,
              parallel_safe: false,
              requires_approval: opts[:approval] && name == "read"
            },
            backend: Backend,
            backend_context: %{test: self()}
          })

        registry
      end)

    options =
      Keyword.merge(
        [
          run_id: "prepare",
          store: Store,
          context: %{table: table, test: self(), gate: opts[:gate]},
          provider: Provider,
          provider_context: %{test: self()},
          hooks: Hooks,
          registry: registry,
          subscriber: self(),
          authority: %{
            caller: "host",
            run_id: "prepare",
            grants: Keyword.get(opts, :grants, ["read", "outer"]),
            tool_revision: 1
          },
          work: 20,
          run_timeout: 5_000
        ],
        Keyword.take(opts, [:effect_timeout, :run_timeout])
      )

    {start_supervised!({Conversation, options}, id: make_ref()), table}
  end
end
