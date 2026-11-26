Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.ConversationCodeModeParallelTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, Goal, GoalFileStore}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Session}
  @moduletag :tmp_dir

  defmodule GoalHost do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  defmodule ResultStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      case meta.command do
        {:tool_completed, _, %{tool_name: "fixture::read"} = invocation} ->
          send(context.test, {:result_ack_waiting, invocation.invocation_id, self()})
          receive do: (:ack -> :ok)

        _ ->
          :ok
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  defmodule Timeouts do
    def tool_effect_timeout(%{tool_name: "fixture::read", arguments: %{"value" => 1}}, _),
      do: {:ok, 1_000}

    def tool_effect_timeout(%{tool_name: "fixture::read"}, _), do: {:ok, 3_000}
    def tool_effect_timeout(_, _), do: :default
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

  defmodule Backend do
    def execute(operation) do
      send(
        operation.backend_context.test,
        {:started, operation.arguments["value"], self(), operation}
      )

      receive do
        :release ->
          {:ok, %{value: operation.arguments["value"]}}

        :missing ->
          {:error, Error.new(:not_found, "fixture missing")}

        :ask ->
          {:ok, answer} = operation.backend_context.interact.(%{kind: :question})
          {:ok, %{value: answer}}
      end
    end
  end

  setup tags do
    assert is_binary(Backplane.AgentRuntime.Codex.CodeMode.RunnerLaunch.executable(nil))
    assert CodeMode.lifecycle_capability(%{}) == :verified
    names = ["exec", "fixture::read", "fixture::write"]
    authority = %{caller: "host", run_id: "parallel", grants: names, tool_revision: 1}
    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority)

    schema = %{
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "integer"}},
      "additionalProperties" => false
    }

    contracts =
      for {name, parallel} <- [{"read", true}, {"write", false}] do
        %{
          name: name,
          namespace: "fixture",
          backend: Backend,
          backend_context: %{test: self()},
          revision: 1,
          schema: schema,
          safety: %{read_only: true, retry_safe: true, parallel_safe: parallel}
        }
      end

    assert {:ok, profile} =
             Codex.profile(
               :mixed,
               %{session_binding: binding, code_mode_contracts: contracts},
               authority,
               tools: names
             )

    assert {:ok, store} = EphemeralStore.new(binding.run_incarnation)

    {store_adapter, store_context} =
      if tags[:gated_results],
        do: {ResultStore, %{table: store, test: self()}},
        else: {EphemeralStore, store}

    {goal_options, goal_store} =
      if tags[:goal] do
        goal_store = start_supervised!({GoalFileStore, tags.tmp_dir})

        goal =
          start_supervised!(
            {Goal,
             thread_id: "parallel-thread",
             owner_pid: self(),
             store: GoalFileStore,
             store_context: goal_store,
             host: GoalHost,
             host_context: nil}
          )

        assert {:ok, _} =
                 Goal.set(goal, %{objective: "complete the reads"}, %{text: "complete the reads"})

        assert {:ok, goal_binding} =
                 Goal.bind(goal, %{
                   thread_id: "parallel-thread",
                   run_id: authority.run_id,
                   incarnation: binding.run_incarnation,
                   authority: authority,
                   usage_authoritative: true,
                   mode: :execution
                 })

        {[goal: goal, goal_binding: goal_binding, thread_id: "parallel-thread"], goal_store}
      else
        {[], nil}
      end

    conversation =
      start_supervised!(
        {Conversation,
         goal_options ++
           [hooks: if(tags[:independent_timeouts], do: Timeouts)] ++
           [
             run_id: authority.run_id,
             incarnation: binding.run_incarnation,
             store: store_adapter,
             context: store_context,
             provider: Provider,
             provider_context: %{test: self()},
             subscriber: self(),
             registry: profile.registry,
             tools: profile.tools,
             authority: profile.authority,
             session_binding: binding,
             schema_admission: :strict,
             run_timeout: 15_000,
             effect_timeout: 5_000
           ]}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "read concurrently")
    assert_receive {:provider, _, provider}, 3_000

    %{
      conversation: conversation,
      provider: provider,
      session: session,
      store: store,
      goal_store: goal_store
    }
  end

  test "parallel reads overlap while exclusive calls fence later reads in JavaScript order",
       ctx do
    call(ctx.provider, """
    const values = await Promise.all([
      tools.fixture__read({value: 1}), tools.fixture__read({value: 2}),
      tools.fixture__write({value: 3}),
      tools.fixture__read({value: 4}), tools.fixture__read({value: 5})
    ]);
    return values.map(result => result.value);
    """)

    assert_receive {:started, 1, first, first_operation}, 3_000
    assert_receive {:started, 2, second, second_operation}, 3_000
    refute_receive {:started, _, _, _}, 20
    send(second, :release)

    assert_receive {:agent_runtime, "parallel",
                    %{type: :tool_settled, invocation: %{invocation_id: second_id}}},
                   3_000

    assert second_id == second_operation.invocation_id
    refute_receive {:started, _, _, _}, 20
    send(first, :release)
    assert_receive {:started, 3, exclusive, exclusive_operation}, 3_000
    refute_receive {:started, _, _, _}, 20
    send(exclusive, :release)
    assert_receive {:started, 4, fourth, fourth_operation}, 3_000
    assert_receive {:started, 5, fifth, fifth_operation}, 3_000
    send(fifth, :release)
    send(fourth, :release)
    assert_receive {:provider, %{messages: messages}, provider}, 5_000

    assert %{is_error: false, status: :completed, value: [1, 2, 3, 4, 5]} =
             List.last(messages).result

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "parallel", %{type: :run_completed}}, 3_000
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.store, "parallel")
    assert run.active_tools == %{}

    for operation <- [
          first_operation,
          second_operation,
          exclusive_operation,
          fourth_operation,
          fifth_operation
        ] do
      assert run.execution_intents["tool:#{operation.invocation_id}"].status == :consumed

      assert run.tool_results[operation.invocation_id] == %{
               is_error: false,
               value: operation.arguments["value"]
             }

      assert operation.enclosing_invocation_id == List.last(messages).invocation_id
    end

    refute_receive {:started, _, _, _}, 20
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "cancellation joins every parallel backend and prevents a queued exclusive call", ctx do
    call(ctx.provider, """
    return await Promise.all([
      tools.fixture__read({value: 1}), tools.fixture__read({value: 2}),
      tools.fixture__write({value: 3})
    ]);
    """)

    assert_receive {:started, 1, first, _}, 3_000
    assert_receive {:started, 2, second, _}, 3_000
    first_ref = Process.monitor(first)
    second_ref = Process.monitor(second)
    state = :sys.get_state(ctx.conversation)
    worker = state.effect.native_code_mode.worker
    worker_ref = Process.monitor(worker)
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    assert :ok = Conversation.cancel(ctx.conversation)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 3_000
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}, 3_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3_000
    assert_receive {:agent_runtime, "parallel", %{type: :run_cancelled}}, 3_000
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
    refute_receive {:started, _, _, _}, 20
  end

  @tag gated_results: true, goal: true
  test "sibling completion waits for the current Store and Goal acknowledgements", ctx do
    call(ctx.provider, """
    return await Promise.all([
      tools.fixture__read({value: 1}), tools.fixture__read({value: 2}),
      tools.fixture__write({value: 3})
    ]);
    """)

    assert_receive {:started, 1, first, first_operation}, 3_000
    assert_receive {:started, 2, second, second_operation}, 3_000
    goal_token = GoalFileStore.delay_next_cas(ctx.goal_store, self())
    send(first, :release)
    first_id = first_operation.invocation_id
    assert_receive {:result_ack_waiting, ^first_id, first_writer}, 3_000
    send(second, :release)
    refute_receive {:result_ack_waiting, _, _}, 20
    refute_receive {:started, 3, _, _}, 20
    send(first_writer, :ack)
    assert_receive {:goal_cas_waiting, goal_writer, ^goal_token}, 3_000
    refute_receive {:result_ack_waiting, _, _}, 20
    refute_receive {:started, 3, _, _}, 20
    send(goal_writer, {:release_goal_cas, goal_token})
    second_id = second_operation.invocation_id
    assert_receive {:result_ack_waiting, ^second_id, second_writer}, 3_000
    refute_receive {:started, 3, _, _}, 20
    send(second_writer, :ack)
    assert_receive {:started, 3, exclusive, _}, 3_000
    send(exclusive, :release)
    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert %{is_error: false, status: :completed, value: values} = List.last(messages).result
    assert Enum.map(values, & &1["value"]) == [1, 2, 3]
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "parallel", %{type: :run_completed}}, 3_000
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.store, "parallel")
    assert run.context.conversation.goal_outbox == []
    assert run.active_tools == %{}
  end

  test "Promise.allSettled correlates a rejected read while its sibling continues", ctx do
    call(ctx.provider, """
    const results = await Promise.allSettled([
      tools.fixture__read({value: 1}), tools.fixture__read({value: 2})
    ]);
    return results.map(result => result.status === 'fulfilled' ? result.value.value : result.reason.message);
    """)

    assert_receive {:started, 1, first, first_operation}, 3_000
    assert_receive {:started, 2, second, second_operation}, 3_000
    send(second, :missing)
    second_id = second_operation.invocation_id

    assert_receive {:agent_runtime, "parallel",
                    %{type: :tool_settled, invocation: %{invocation_id: ^second_id}}},
                   3_000

    assert Process.alive?(first)
    send(first, :release)
    assert_receive {:provider, %{messages: messages}, provider}, 3_000

    assert %{is_error: false, status: :completed, value: [1, "fixture missing"]} =
             List.last(messages).result

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "parallel", %{type: :run_completed}}, 3_000
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.store, "parallel")
    assert run.tool_results[first_operation.invocation_id].value == 1
    assert run.tool_results[second_id].is_error == true
  end

  @tag independent_timeouts: true
  test "each parallel read keeps its selected deadline when its sibling times out", ctx do
    call(ctx.provider, """
    const results = await Promise.allSettled([
      tools.fixture__read({value: 1}), tools.fixture__read({value: 2})
    ]);
    return results.map(result => result.status === 'fulfilled' ? result.value.value : result.reason.message);
    """)

    assert_receive {:started, 1, first, first_operation}, 3_000
    assert_receive {:started, 2, second, second_operation}, 3_000

    assert {:ok, %{selected_timeout_ms: 1_000}} =
             first_operation.backend_context.effect_deadline.()

    assert {:ok, %{selected_timeout_ms: 3_000}} =
             second_operation.backend_context.effect_deadline.()

    first_ref = Process.monitor(first)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 2_000
    assert Process.alive?(second)

    assert {:ok, %{selected_timeout_ms: 3_000, remaining_ms: remaining}} =
             second_operation.backend_context.effect_deadline.()

    assert remaining > 0
    send(ctx.conversation, {:nested_timeout, make_ref(), make_ref()})
    send(second, :release)
    assert_receive {:provider, %{messages: messages}, provider}, 3_000

    assert %{is_error: false, value: ["nested tool execution timed out", 2]} =
             List.last(messages).result

    assert {:error, %Error{class: :resource_conflict}} =
             first_operation.backend_context.effect_deadline.()

    assert {:error, %Error{class: :resource_conflict}} =
             second_operation.backend_context.effect_deadline.()

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "parallel", %{type: :run_completed}}, 3_000
  end

  test "early JavaScript exit joins an unawaited sibling and retains uncertain execution", ctx do
    call(ctx.provider, """
    const first = tools.fixture__read({value: 1});
    tools.fixture__read({value: 2});
    await first;
    exit();
    """)

    assert_receive {:started, 1, first, _}, 3_000
    assert_receive {:started, 2, second, _}, 3_000
    second_ref = Process.monitor(second)
    send(first, :release)
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}, 3_000
    await_terminal(ctx.conversation, System.monotonic_time(:millisecond) + 3_000)
    assert Conversation.status(ctx.conversation).run.state == :unknown_outcome
    refute_receive {:provider, _, _}, 20
  end

  test "human input freezes both live deadlines and defers sibling settlement until resolution",
       ctx do
    call(ctx.provider, """
    return await Promise.all([tools.fixture__read({value: 1}), tools.fixture__read({value: 2})]);
    """)

    assert_receive {:started, 1, first, first_operation}, 3_000
    assert_receive {:started, 2, second, second_operation}, 3_000
    send(first, :ask)

    assert_receive {:agent_runtime, "parallel",
                    %{type: :interaction_requested, interaction_id: id}},
                   3_000

    assert {:ok, %{paused: true} = first_deadline} =
             first_operation.backend_context.effect_deadline.()

    assert {:ok, %{paused: true}} = second_operation.backend_context.effect_deadline.()
    send(second, :release)
    refute_receive {:agent_runtime, "parallel", %{type: :tool_settled}}, 20
    assert {:ok, ^first_deadline} = first_operation.backend_context.effect_deadline.()
    assert :ok = Conversation.resolve(ctx.conversation, id, "continue")
    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert %{is_error: false, status: :completed, value: values} = List.last(messages).result
    assert Enum.map(values, & &1["value"]) == ["continue", 2]
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "parallel", %{type: :run_completed}}, 3_000
  end

  test "queued cancellation can retire QuickBEAM while native submissions await their owner",
       ctx do
    call(ctx.provider, """
    await new Promise(resolve => setTimeout(resolve, 1000));
    return await Promise.all([tools.fixture__read({value: 1}), tools.fixture__read({value: 2})]);
    """)

    worker = await_worker(ctx.conversation, System.monotonic_time(:millisecond) + 2_000)
    worker_ref = Process.monitor(worker)
    :sys.suspend(ctx.conversation)
    cancel = Task.async(fn -> Conversation.cancel(ctx.conversation) end)

    try do
      await_cancel_message(ctx.conversation, System.monotonic_time(:millisecond) + 2_000)
      await_submissions(worker, 2, System.monotonic_time(:millisecond) + 2_000)
      assert {:ok, _} = CodeMode.Worker.os_identity(worker)
    after
      :sys.resume(ctx.conversation)
    end

    assert :ok = Task.await(cancel)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3_000
    await_terminal(ctx.conversation, System.monotonic_time(:millisecond) + 3_000)
    refute_receive {:started, _, _, _}, 20
  end

  defp await_worker(conversation, deadline) do
    case get_in(:sys.get_state(conversation), [:effect, :native_code_mode, :worker]) do
      worker when is_pid(worker) ->
        worker

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await_worker(conversation, deadline)
    end
  end

  defp await_cancel_message(conversation, deadline) do
    {:messages, messages} = Process.info(conversation, :messages)

    if not Enum.any?(messages, &match?({:"$gen_call", _, :cancel}, &1)) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_cancel_message(conversation, deadline)
    end
  end

  defp await_submissions(worker, count, deadline) do
    if map_size(:sys.get_state(worker, 500).submissions) != count do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_submissions(worker, count, deadline)
    end
  end

  defp await_terminal(conversation, deadline) do
    if Conversation.status(conversation).phase != :terminal do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_terminal(conversation, deadline)
    end
  end

  defp call(provider, source) do
    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "parallel-exec", name: "exec", arguments: source}
         },
         %{type: :response_completed, message: %{role: :assistant, content: "reading"}}
       ]}
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
