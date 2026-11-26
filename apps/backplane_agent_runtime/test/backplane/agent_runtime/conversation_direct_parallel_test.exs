Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.ConversationDirectParallelTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Conversation,
    EphemeralStore,
    Error,
    ToolRegistry,
    Goal,
    GoalFileStore
  }

  @moduletag :tmp_dir

  defmodule GoalHost do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

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

  defmodule Backend do
    def execute(operation) do
      send(
        operation.backend_context.test,
        {:started, operation.arguments["value"], self(), operation}
      )

      receive do
        :release ->
          {:ok, %{value: operation.arguments["value"]}}

        :uncertain ->
          {:error, Error.new(:unknown_outcome, "fixture outcome unknown")}

        :feedback ->
          send(
            operation.backend_context.test,
            {:feedback,
             operation.backend_context.append_feedback.(%{
               id: "feedback-1",
               text: "direct feedback",
               source: "fixture",
               stage: "PostToolUse"
             })}
          )

          {:ok, %{value: operation.arguments["value"]}}
      end
    end
  end

  defmodule Timeouts do
    def tool_effect_timeout(%{arguments: %{"value" => 1}}, _), do: {:ok, 100}
    def tool_effect_timeout(_, _), do: {:ok, 2_000}
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      case meta.command do
        {:tool_completed, _, invocation} ->
          send(context.test, {:store_waiting, invocation.tool_call_id, self()})

          receive do
            :ack -> EphemeralStore.store(context.table, run, meta)
            :fail -> {:error, Error.new(:execution_failure, "disk unavailable")}
          end

        _ ->
          EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  setup tags do
    {:ok, registry} =
      Enum.reduce([{"read", true}, {"write", false}], {:ok, %ToolRegistry{}}, fn {name, safe},
                                                                                 {:ok, registry} ->
        ToolRegistry.register(registry, %{
          tool_name: name,
          tool_revision: 1,
          schema: %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "integer"}},
            "required" => ["value"]
          },
          safety: %{
            read_only: true,
            retry_safe: true,
            parallel_safe: safe,
            requires_approval: false
          },
          backend: Backend,
          backend_context: %{test: self()}
        })
      end)

    {:ok, store} = EphemeralStore.new(1)

    {adapter, context} =
      if tags[:gated],
        do: {GatedStore, %{table: store, test: self()}},
        else: {EphemeralStore, store}

    {goal_options, goal_store} =
      if tags[:goal] do
        goal_store = start_supervised!({GoalFileStore, tags.tmp_dir})

        goal =
          start_supervised!(
            {Goal,
             thread_id: "direct-thread",
             owner_pid: self(),
             store: GoalFileStore,
             store_context: goal_store,
             host: GoalHost,
             host_context: nil}
          )

        assert {:ok, _} = Goal.set(goal, %{objective: "read"}, %{text: "read"})

        assert {:ok, binding} =
                 Goal.bind(goal, %{
                   thread_id: "direct-thread",
                   run_id: "direct-parallel",
                   incarnation: 1,
                   authority: %{
                     caller: "host",
                     run_id: "direct-parallel",
                     grants: ["read", "write"],
                     tool_revision: 1
                   },
                   usage_authoritative: true,
                   mode: :execution
                 })

        {[goal: goal, goal_binding: binding, thread_id: "direct-thread"], goal_store}
      else
        {[], nil}
      end

    pid =
      start_supervised!(
        {Conversation,
         goal_options ++
           [
             run_id: "direct-parallel",
             incarnation: 1,
             store: adapter,
             context: context,
             provider: Provider,
             provider_context: %{test: self()},
             subscriber: self(),
             registry: registry,
             authority: %{
               caller: "host",
               run_id: "direct-parallel",
               grants: ["read", "write"],
               tool_revision: 1
             },
             hooks: if(tags[:timeouts], do: Timeouts),
             work: 30,
             run_timeout: 10_000,
             effect_timeout: 5_000
           ]}
      )

    assert {:ok, _} = Conversation.prompt(pid, "parallel tools")
    assert_receive {:provider, _, provider}

    %{
      conversation: pid,
      provider: provider,
      store: store,
      registry: registry,
      goal_store: goal_store
    }
  end

  test "direct reads overlap, settle reverse order, preserve model order, and fence unsafe calls",
       c do
    calls(c.provider, [{"read", 1}, {"read", 2}, {"write", 3}, {"read", 4}, {"read", 5}])
    assert_receive {:started, 1, first, first_op}
    assert_receive {:started, 2, second, second_op}
    assert first_op.tool_call_id == "call-1"
    assert second_op.tool_call_id == "call-2"
    assert first_op.enclosing_invocation_id == first_op.invocation_id
    assert second_op.enclosing_invocation_id == second_op.invocation_id
    send(second, :release)

    assert_receive {:agent_runtime, "direct-parallel",
                    %{type: :tool_settled, invocation: %{tool_call_id: "call-2"}}}

    refute_receive {:started, 3, _, _}, 20
    refute_receive {:provider, _, _}, 20
    send(first, :release)
    assert_receive {:started, 3, third, _}
    refute_receive {:started, 4, _, _}, 20
    send(third, :release)
    assert_receive {:started, 4, fourth, _}
    assert_receive {:started, 5, fifth, _}
    send(fifth, :release)
    send(fourth, :release)
    assert_receive {:provider, %{messages: messages}, _}
    tools = Enum.filter(messages, &(&1.role == :tool))
    assert Enum.map(tools, & &1.tool_call_id) == Enum.map(1..5, &"call-#{&1}")
    assert Enum.map(tools, & &1.result.value) == Enum.to_list(1..5)
    assert {:ok, %{run: run}} = EphemeralStore.load(c.store, "direct-parallel")
    assert run.active_tools == %{}
    assert map_size(run.tool_results) == 5
  end

  test "cancel joins all active direct siblings and never starts queued barrier", c do
    calls(c.provider, [{"read", 1}, {"read", 2}, {"write", 3}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, _}
    refs = for pid <- [first, second], do: {pid, Process.monitor(pid)}
    assert :ok = Conversation.cancel(c.conversation)
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
    assert_receive {:agent_runtime, "direct-parallel", %{type: :run_cancelled}}
    refute_receive {:started, 3, _, _}, 20
  end

  test "live sibling callbacks keep independent identity and deadlines", c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, first, first_op}
    assert_receive {:started, 2, second, second_op}
    assert {:ok, %{selected_timeout_ms: 5_000}} = first_op.backend_context.effect_deadline.()
    assert :ok = first_op.backend_context.emit.(%{type: :async_user_message, message: "first"})
    assert :ok = second_op.backend_context.emit.(%{type: :async_user_message, message: "second"})

    assert_receive {:agent_runtime, "direct-parallel",
                    %{type: :async_user_message, tool_call_id: "call-1"}}

    assert_receive {:agent_runtime, "direct-parallel",
                    %{type: :async_user_message, tool_call_id: "call-2"}}

    send(first, :feedback)
    assert_receive {:feedback, {:ok, feedback}}
    assert feedback.correlation.tool_call_id == "call-1"
    assert feedback.correlation.enclosing_invocation_id == first_op.invocation_id
    refute_receive {:provider, _, _}, 20
    send(second, :release)
    assert_receive {:provider, %{messages: messages}, _}

    assert Enum.map(Enum.filter(messages, &(&1.role == :tool)), & &1.tool_call_id) == [
             "call-1",
             "call-2"
           ]

    assert {:error, %Error{class: :resource_conflict}} =
             first_op.backend_context.effect_deadline.()
  end

  test "uncertain sibling outcome stays uncertain and does not manufacture any result", c do
    calls(c.provider, [{"read", 1}, {"read", 2}, {"write", 3}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, _}
    ref = Process.monitor(first)
    send(second, :uncertain)
    assert_receive {:DOWN, ^ref, :process, ^first, _}
    assert_receive {:agent_runtime, "direct-parallel", %{type: :run_cancelled}}
    refute_receive {:provider, _, _}, 20
    refute_receive {:started, 3, _, _}, 20
    assert {:ok, %{run: run}} = EphemeralStore.load(c.store, "direct-parallel")
    assert run.tool_results == %{}
    assert get_in(run.outcome, ["cleanup", "certainty"]) == "uncertain"
  end

  @tag goal: true
  test "Goal ACK blocks sibling settlements and the next provider boundary", c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, _}
    token = GoalFileStore.delay_next_cas(c.goal_store, self())
    send(first, :release)
    assert_receive {:goal_cas_waiting, writer, ^token}
    send(second, :release)

    refute_receive {:agent_runtime, "direct-parallel",
                    %{type: :tool_settled, invocation: %{tool_call_id: "call-2"}}},
                   20

    refute_receive {:provider, _, _}, 20
    send(writer, {:release_goal_cas, token})
    assert_receive {:provider, %{messages: messages}, _}

    assert Enum.map(Enum.filter(messages, &(&1.role == :tool)), & &1.tool_call_id) == [
             "call-1",
             "call-2"
           ]

    assert {:ok, record} = GoalFileStore.load(c.goal_store, "direct-thread")
    assert record.goal.status == :active
    assert {:ok, %{run: run}} = EphemeralStore.load(c.store, "direct-parallel")
    assert map_size(run.tool_results) == 2
    assert run.active_tools == %{}
  end

  test "a direct catalog producer publishes after the entire pinned batch", c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, first, first_op}
    assert_receive {:started, 2, second, second_op}

    authority = %{
      caller: "host",
      run_id: "direct-parallel",
      grants: ["read", "write"],
      tool_revision: 1
    }

    update = %{
      publication_id: "direct-2",
      run_id: "direct-parallel",
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: c.registry,
        authority: authority,
        tools:
          Enum.map(c.registry.tools, fn {name, tool} ->
            %{name: name, description: Map.get(tool, :description, name), parameters: tool.schema}
          end)
      }
    }

    assert {:ok, %{status: :staged}} = first_op.backend_context.stage_catalog.(update)
    send(first, :release)

    assert_receive {:agent_runtime, "direct-parallel",
                    %{type: :tool_settled, invocation: %{tool_call_id: "call-1"}}}

    assert second_op.backend_context.catalog_snapshot.revision == 1
    assert Conversation.status(c.conversation).catalog_revision == 1
    refute_receive {:provider, _, _}, 20
    send(second, :release)
    assert_receive {:provider, %{catalog_revision: 2}, _}
    assert Conversation.status(c.conversation).catalog_revision == 2
  end

  @tag timeouts: true
  test "a direct sibling timeout preserves the other live deadline", c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, second_op}
    ref = Process.monitor(first)
    assert_receive {:DOWN, ^ref, :process, ^first, _}
    assert Process.alive?(second)

    assert {:ok, %{selected_timeout_ms: 2_000, remaining_ms: remaining}} =
             second_op.backend_context.effect_deadline.()

    assert remaining > 0
    send(second, :release)
    assert_receive {:provider, %{messages: messages}, _}
    [failed, success] = Enum.filter(messages, &(&1.role == :tool))
    assert failed.result.is_error
    assert success.result.value == 2
  end

  @tag gated: true
  test "reverse completions wait for separate Store ACKs and retain model projection order", c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, _}
    send(second, :release)
    assert_receive {:store_waiting, "call-2", writer}
    send(first, :release)
    refute_receive {:store_waiting, "call-1", _}, 20
    refute_receive {:provider, _, _}, 20
    send(writer, :ack)
    assert_receive {:store_waiting, "call-1", writer}
    refute_receive {:provider, _, _}, 20
    send(writer, :ack)
    assert_receive {:provider, %{messages: messages}, _}

    assert Enum.map(Enum.filter(messages, &(&1.role == :tool)), & &1.tool_call_id) == [
             "call-1",
             "call-2"
           ]
  end

  test "cold restore retains active invocation facts without executing or manufacturing results",
       c do
    calls(c.provider, [{"read", 1}, {"read", 2}])
    assert_receive {:started, 1, _, _}
    assert_receive {:started, 2, _, _}
    assert {:ok, %{run: run}} = EphemeralStore.load(c.store, "direct-parallel")
    assert map_size(run.active_tools) == 2
    opts = :sys.get_state(c.conversation).opts
    recovered = start_supervised!({Conversation, Keyword.put(opts, :run, run)}, id: :recovered)
    assert Conversation.status(recovered).phase == :recovery_required
    refute_receive {:started, _, _, _}, 20
    refute_receive {:provider, _, _}, 20
    assert {:ok, %{run: current}} = EphemeralStore.load(c.store, "direct-parallel")
    assert current.tool_results == %{}
  end

  @tag gated: true
  test "completion ACKs serialize and failed Store cancels every remaining sibling", c do
    calls(c.provider, [{"read", 1}, {"read", 2}, {"write", 3}])
    assert_receive {:started, 1, first, _}
    assert_receive {:started, 2, second, _}
    second_ref = Process.monitor(second)
    send(first, :release)
    assert_receive {:store_waiting, "call-1", writer}
    refute_receive {:provider, _, _}, 20
    send(writer, :fail)
    assert_receive {:agent_runtime, "direct-parallel", %{type: :storage_failed}}
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}
    refute_receive {:started, 3, _, _}, 20
    assert {:ok, %{run: run}} = EphemeralStore.load(c.store, "direct-parallel")
    assert run.tool_results == %{}
  end

  test "native direct clock siblings cooperate in cancellation without a Code Mode outer effect" do
    alias Backplane.AgentRuntime.Codex
    alias Backplane.AgentRuntime.Codex.Session

    authority = %{
      caller: "host",
      run_id: "clock-direct",
      grants: ["clock::sleep"],
      tool_revision: 1
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, %{session_binding: binding}, authority,
               tools: ["clock::sleep"]
             )

    # This host fixture explicitly permits overlapping waits to exercise every
    # registration during direct-batch cooperative retirement.
    profile = put_in(profile.registry.tools["clock::sleep"].safety.parallel_safe, true)
    assert {:ok, store} = EphemeralStore.new(binding.run_incarnation)

    pid =
      start_supervised!(
        {Conversation,
         run_id: authority.run_id,
         incarnation: binding.run_incarnation,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         run_timeout: 10_000,
         effect_timeout: 5_000},
        id: :clock_direct
      )

    assert {:ok, _} = Conversation.prompt(pid, "wait")
    assert_receive {:provider, _, provider}

    events =
      for value <- 1..2,
          do: %{
            type: :tool_call_completed,
            tool_call: %{
              id: "clock-#{value}",
              name: "clock::sleep",
              arguments: %{"duration_ms" => 60_000}
            }
          }

    send(
      provider,
      {:events,
       events ++ [%{type: :response_completed, message: %{role: :assistant, content: "waiting"}}]}
    )

    assert_receive {:agent_runtime, "clock-direct",
                    %{type: :tool_started, invocation: %{tool_call_id: "clock-1"}}}

    assert_receive {:agent_runtime, "clock-direct",
                    %{type: :tool_started, invocation: %{tool_call_id: "clock-2"}}}

    await_registrations(pid, 100)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "clock-direct", %{type: :run_cancelled}}, 3_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "clock-direct")
    assert run.tool_results == %{}
    assert get_in(run.outcome, ["cleanup", "certainty"]) == "confirmed"
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp await_registrations(_pid, 0), do: flunk("clock registrations missing")

  defp await_registrations(pid, attempts) do
    if map_size(:sys.get_state(pid).cancellations) != 2 do
      Process.sleep(10)
      await_registrations(pid, attempts - 1)
    end
  end

  defp calls(provider, calls) do
    events =
      Enum.map(calls, fn {name, value} ->
        %{
          type: :tool_call_completed,
          tool_call: %{id: "call-#{value}", name: name, arguments: %{"value" => value}}
        }
      end)

    send(
      provider,
      {:events,
       events ++ [%{type: :response_completed, message: %{role: :assistant, content: "tools"}}]}
    )
  end
end
