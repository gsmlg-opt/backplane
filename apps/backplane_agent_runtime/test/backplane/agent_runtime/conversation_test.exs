defmodule Backplane.AgentRuntime.ConversationTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

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
