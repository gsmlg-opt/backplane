defmodule Backplane.AgentRuntime.ConversationToolDeadlineTest do
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
      send(context.test, {:prepare, invocation, self()})
      receive do: ({:prepare, result} -> result)
    end

    def tool_effect_timeout(invocation, context) do
      send(context.test, {:select, invocation, context, self()})

      receive do
        {:select, result} -> result
        :crash -> raise "selector crashed"
      end
    end
  end

  defmodule PreparationOnly do
    defdelegate prepare_tool(invocation, context), to: Hooks
  end

  defmodule Backend do
    def execute(operation) do
      context = operation.backend_context
      send(context.test, {:backend, operation, context.effect_deadline.(), self()})

      receive do
        :finish ->
          {:ok, %{text: "done"}}

        :ask ->
          send(context.test, {:answer, context.interact.(%{kind: :question})})
          receive do: (:finish -> {:ok, %{text: "done"}})

        :nested ->
          result =
            context.nested_dispatch.(%{tool_name: "read", arguments: %{"path" => "nested"}})

          send(context.test, {:nested, result})
          {:ok, %{text: "outer done"}}
      end
    end
  end

  defp start(options \\ []) do
    {:ok, store} = EphemeralStore.new(1)

    registry =
      Enum.reduce(["read", "outer"], %ToolRegistry{}, fn name, registry ->
        {:ok, registry} =
          ToolRegistry.register(registry, %{
            tool_name: name,
            tool_revision: 1,
            codex_input_kind: if(options[:custom], do: :custom, else: :function),
            description: name,
            backend: Backend,
            backend_context: %{test: self(), effect_deadline: :spoofed},
            schema: %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"]
            },
            safety: %{
              read_only: true,
              retry_safe: true,
              parallel_safe: false,
              requires_approval: Keyword.get(options, :approval, false)
            }
          })

        registry
      end)

    opts = [
      run_id: "deadline",
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      registry: registry,
      hooks: Hooks,
      authority: %{
        caller: "host",
        run_id: "deadline",
        grants: ["read", "outer"],
        tool_revision: 1
      },
      subscriber: self(),
      run_timeout: :infinity,
      effect_timeout: 1_000
    ]

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Conversation, Keyword.merge(opts, Keyword.drop(options, [:approval, :tool, :custom]))},
          id: make_ref(),
          restart: :temporary
        )
      )

    assert {:ok, _} = Conversation.prompt(pid, "read")
    assert_receive {:provider, _, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "call",
             name: Keyword.get(options, :tool, "read"),
             arguments: if(options[:custom], do: "original patch", else: %{"path" => "A"})
           }
         },
         done()
       ]}
    )

    assert_receive {:prepare, invocation, worker}, 1_000
    {pid, store, invocation, worker}
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  test "selector sees prepared and approved final input once before intent and getter starts armed" do
    {pid, store, original, preparation} = start(approval: true)
    send(preparation, {:prepare, {:allow, %{"path" => "B"}}})

    assert_receive {:agent_runtime, "deadline",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    assert :ok = Conversation.resolve(pid, id, {:update_input, %{"path" => "C"}})

    assert_receive {:agent_runtime, "deadline",
                    %{type: :interaction_requested, interaction_id: updated}},
                   1_000

    refute_receive {:select, _, _, _}, 5
    assert :ok = Conversation.resolve(pid, updated, :approved)
    assert_receive {:select, selected, context, selector}, 1_000
    assert selected.arguments == %{"path" => "C"}
    assert selected.invocation_id == original.invocation_id
    assert context.input_kind == :function
    assert context.catalog_snapshot.revision == 1

    refute Enum.any?(
             [:interact, :nested_dispatch, :stage_catalog, :emit, :append_feedback],
             &Map.has_key?(context, &1)
           )

    assert {:ok, %{run: run}} = EphemeralStore.load(store, "deadline")
    assert run.active_tools == %{}
    send(selector, {:select, {:ok, 2_147_360_000}})
    assert_receive {:backend, operation, {:ok, first}, backend}, 1_000
    assert operation.arguments == selected.arguments
    assert first.selected_timeout_ms == 2_147_360_000
    assert first.remaining_ms > 2_147_000_000
    assert abs(first.deadline_ms - first.remaining_ms - System.monotonic_time(:millisecond)) < 50
    Process.sleep(15)
    assert {:ok, later} = operation.backend_context.effect_deadline.()
    assert later.remaining_ms < first.remaining_ms
    refute_receive {:select, _, _, _}, 10
    send(backend, :finish)
    assert_receive {:provider, _, provider}, 1_000

    assert {:error, %Error{class: :resource_conflict}} =
             operation.backend_context.effect_deadline.()

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "deadline", %{type: :run_completed}}, 1_000
  end

  test "raw custom selection receives exact prepared bytes and keeps shared limits" do
    {_pid, _, original, preparation} = start(custom: true)
    send(preparation, {:prepare, {:allow, "final patch\r\n你好"}})
    assert_receive {:select, selected, context, selector}, 1_000
    assert selected.arguments == "final patch\r\n你好"
    assert selected.invocation_id == original.invocation_id
    assert context.input_kind == :custom
    send(selector, {:select, {:ok, 3_600_001}})
    assert_receive {:backend, operation, {:ok, budget}, worker}, 1_000
    assert operation.arguments == selected.arguments
    assert budget.selected_timeout_ms == 3_600_001

    assert {:error, %Error{class: :validation}} =
             Backplane.AgentRuntime.Execution.validate_limits(effect_timeout: 3_600_001)

    send(worker, :finish)
  end

  test "default and omitted selector retain effect default; maximum timer is admitted" do
    for hooks <- [Hooks, PreparationOnly] do
      {_pid, _store, _invocation, preparation} = start(hooks: hooks)
      send(preparation, {:prepare, :allow})

      if hooks == Hooks do
        assert_receive {:select, _, _, selector}, 1_000
        send(selector, {:select, :default})
      end

      assert_receive {:backend, _, {:ok, budget}, worker}, 1_000
      assert budget.selected_timeout_ms == 1_000
      assert budget.remaining_ms in 1..1_000
      send(worker, :finish)
      assert_receive {:provider, _, _}, 1_000
    end

    for selected <- [2_147_000_000, 2_147_483_647] do
      {_pid, _, _, preparation} = start()
      send(preparation, {:prepare, :allow})
      assert_receive {:select, _, _, selector}, 1_000
      send(selector, {:select, {:ok, selected}})
      assert_receive {:backend, operation, {:ok, budget}, worker}, 1_000
      assert budget.selected_timeout_ms == selected
      assert budget.remaining_ms > selected - 1_000
      send(worker, :finish)
      assert_receive {:provider, _, _}, 1_000

      assert {:error, %Error{class: :resource_conflict}} =
               operation.backend_context.effect_deadline.()
    end
  end

  test "invalid selection is a pre-intent rejection with no backend or retry" do
    for {result, class} <- [
          {{:ok, 0}, :validation},
          {{:ok, -1}, :validation},
          {{:ok, :infinity}, :validation},
          {{:ok, 2_147_483_648}, :validation},
          {{:ok, 1.5}, :validation},
          {:invalid, :malformed_result},
          {{:error, Error.new(:forbidden, "host denial")}, :forbidden},
          {:crash, :execution_failure}
        ] do
      {_pid, store, _, preparation} = start()
      send(preparation, {:prepare, :allow})
      assert_receive {:select, _, _, selector}, 1_000
      if result == :crash, do: send(selector, :crash), else: send(selector, {:select, result})
      assert_receive {:provider, request, _}, 1_000
      assert List.last(request.messages).result.error.class == class
      assert {:ok, %{run: run}} = EphemeralStore.load(store, "deadline")
      assert run.active_tools == %{}

      assert Enum.all?(
               Map.keys(Map.get(run, :execution_intents, %{})),
               &(not String.starts_with?(&1, "tool:"))
             )

      refute_receive {:backend, _, _, _}, 5
      refute_receive {:select, _, _, _}, 5
    end
  end

  test "selection uses the remaining admission allowance and cancellation kills selector" do
    {pid, store, _, preparation} = start(effect_timeout: 200)
    send(preparation, {:prepare, :allow})
    assert_receive {:select, _, _, selector}, 1_000
    selector_ref = Process.monitor(selector)
    state = :sys.get_state(pid)
    remaining = state.tool_admission_deadline - System.monotonic_time(:millisecond)
    assert remaining <= 200
    assert state.preparation.live_deadline <= state.tool_admission_deadline
    assert :ok = Conversation.cancel(pid)
    assert_receive {:DOWN, ^selector_ref, :process, ^selector, _}, 1_000
    send(selector, {:select, {:ok, 1_000}})
    assert_receive {:agent_runtime, "deadline", %{type: :run_cancelled}}, 1_000
    refute_receive {:backend, _, _, _}, 10
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "deadline")
    assert run.active_tools == %{}
  end

  test "selection exhaustion never commits or dispatches" do
    {_pid, store, _, preparation} = start(effect_timeout: 80)
    Process.sleep(35)
    send(preparation, {:prepare, :allow})
    assert_receive {:select, _, _, selector}, 1_000
    ref = Process.monitor(selector)
    assert_receive {:DOWN, ^ref, :process, ^selector, _}, 1_000
    assert_receive {:agent_runtime, "deadline", %{type: :run_cancelled}}, 1_000
    refute_receive {:backend, _, _, _}, 10
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "deadline")
    assert run.active_tools == %{}
  end

  test "root clips selection and a short effect deadline stops the live worker" do
    {pid, _, _, preparation} = start(run_timeout: 2_500)
    send(preparation, {:prepare, :allow})
    assert_receive {:select, _, _, selector}, 1_000
    send(selector, {:select, {:ok, 30_000}})
    assert_receive {:backend, operation, {:ok, budget}, worker}, 1_000
    assert budget.selected_timeout_ms == 30_000
    assert budget.remaining_ms in 1..2_500
    assert :ok = Conversation.cancel(pid)

    assert {:error, %Error{class: :resource_conflict}} =
             operation.backend_context.effect_deadline.()

    refute Process.alive?(worker)

    {_pid, _, _, preparation} = start()
    send(preparation, {:prepare, :allow})
    assert_receive {:select, _, _, selector}, 1_000
    send(selector, {:select, {:ok, 40}})
    assert_receive {:backend, operation, {:ok, budget}, worker}, 1_000
    assert budget.remaining_ms in 1..40
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert_receive {:agent_runtime, "deadline", %{type: :run_cancelled}}, 1_000

    assert {:error, %Error{class: :resource_conflict}} =
             operation.backend_context.effect_deadline.()
  end

  test "direct human wait freezes deadline and fences the timer generation" do
    {pid, _, _, preparation} = start()
    send(preparation, {:prepare, :allow})
    assert_receive {:select, _, _, selector}, 1_000
    send(selector, {:select, {:ok, 180}})
    assert_receive {:backend, operation, {:ok, _}, worker}, 1_000
    state = :sys.get_state(pid)
    old_timer = {:timeout, state.effect.task.ref, state.effect.timer_generation}
    send(worker, :ask)

    assert_receive {:agent_runtime, "deadline",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    assert {:ok, frozen} = operation.backend_context.effect_deadline.()
    assert frozen.paused and frozen.deadline_ms == nil
    Process.sleep(220)
    assert {:ok, ^frozen} = operation.backend_context.effect_deadline.()
    assert :ok = Conversation.resolve(pid, id, :approved)
    assert_receive {:answer, {:ok, :approved}}, 1_000
    send(pid, old_timer)
    assert {:ok, resumed} = operation.backend_context.effect_deadline.()
    refute resumed.paused
    assert resumed.remaining_ms <= frozen.remaining_ms
    assert is_integer(resumed.deadline_ms)
    send(worker, :finish)
    assert_receive {:provider, _, _}, 1_000
    refute_receive {:select, _, _, _}, 10
  end

  test "nested selection cannot extend outer budget and both getters pause and resume" do
    {pid, _, _, preparation} = start(tool: "outer")
    send(preparation, {:prepare, :allow})
    assert_receive {:select, outer_invocation, _, selector}, 1_000
    send(selector, {:select, {:ok, 450}})
    assert_receive {:backend, outer, {:ok, _}, outer_worker}, 1_000
    send(outer_worker, :nested)
    assert_receive {:prepare, nested_invocation, preparation}, 1_000
    assert nested_invocation.invocation_id != outer_invocation.invocation_id
    send(preparation, {:prepare, :allow})
    assert_receive {:select, ^nested_invocation, context, selector}, 1_000
    assert context.catalog_snapshot.revision == outer.catalog_revision
    send(selector, {:select, {:ok, 30_000}})
    assert_receive {:backend, nested, {:ok, budget}, nested_worker}, 1_000
    assert budget.selected_timeout_ms == 30_000
    assert budget.remaining_ms in 1..450
    send(nested_worker, :ask)

    assert_receive {:agent_runtime, "deadline",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    assert {:ok, outer_paused} = outer.backend_context.effect_deadline.()
    assert {:ok, nested_paused} = nested.backend_context.effect_deadline.()
    assert outer_paused.paused and nested_paused.paused
    Process.sleep(480)
    assert {:ok, ^outer_paused} = outer.backend_context.effect_deadline.()
    assert {:ok, ^nested_paused} = nested.backend_context.effect_deadline.()
    assert :ok = Conversation.resolve(pid, id, :approved)
    assert_receive {:answer, {:ok, :approved}}, 1_000
    assert {:ok, resumed} = nested.backend_context.effect_deadline.()
    refute resumed.paused
    assert resumed.remaining_ms <= nested_paused.remaining_ms
    send(nested_worker, :finish)
    assert_receive {:nested, {:ok, %{text: "done"}}}, 1_000
    assert_receive {:provider, _, _}, 1_000
    assert {:error, %Error{class: :resource_conflict}} = nested.backend_context.effect_deadline.()
    assert {:error, %Error{class: :resource_conflict}} = outer.backend_context.effect_deadline.()
  end

  test "worker DOWN and owner death invalidate retained deadline callbacks" do
    for death <- [:worker, :owner] do
      {pid, _, _, preparation} = start()
      send(preparation, {:prepare, :allow})
      assert_receive {:select, _, _, selector}, 1_000
      send(selector, {:select, {:ok, 3_000}})
      assert_receive {:backend, operation, {:ok, _}, worker}, 1_000
      ref = Process.monitor(worker)
      Process.exit(if(death == :worker, do: worker, else: pid), :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000

      assert {:error, %Error{class: :resource_conflict}} =
               operation.backend_context.effect_deadline.()
    end
  end
end
