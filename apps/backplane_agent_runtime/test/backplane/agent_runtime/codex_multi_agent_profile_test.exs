defmodule Backplane.AgentRuntime.CodexMultiAgentProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule RootProvider do
    def stream(request, context) do
      send(context.test, {:root_provider, request, self()})
      event_stream()
    end

    defp event_stream do
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

  defmodule ChildProvider do
    def stream(request, context) do
      send(context.test, {:child_provider, request.run_id, request, self()})

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

  defmodule FailCleanupStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(%{table: table}, run, meta) do
      if elem(meta.command, 0) == :cleanup_settled do
        {:error,
         Backplane.AgentRuntime.Error.new(:execution_failure, "cleanup acknowledgement lost")}
      else
        EphemeralStore.store(table, run, meta)
      end
    end
  end

  defp child_options(test_pid, _request, run_id, _parent) do
    {:ok, store} = EphemeralStore.new(1)

    {:ok,
     [
       run_id: run_id,
       store: EphemeralStore,
       context: store,
       provider: ChildProvider,
       provider_context: %{test: test_pid},
       registry: %ToolRegistry{},
       tools: [],
       authority: %{caller: "host", run_id: run_id, grants: []},
       schema_admission: :strict,
       work: 10,
       run_timeout: 5_000
     ]}
  end

  defp start_runtime(test_pid) do
    MultiAgent.start_link(
      parent_run_id: "root",
      parent_name: "/root",
      parent_authority: %{caller: "host", run_id: "root", grants: []},
      child_options: &child_options(test_pid, &1, &2, &3),
      min_wait_timeout_ms: 0
    )
  end

  defp call(runtime, profile, run_id, tool_name, arguments) do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: profile},
      run_id: run_id,
      tool_name: tool_name,
      arguments: arguments
    })
  end

  defp wait_for_waiters(runtime, expected, attempts \\ 50)

  defp wait_for_waiters(_runtime, _expected, 0), do: false

  defp wait_for_waiters(runtime, expected, attempts) do
    if map_size(:sys.get_state(runtime).waiters) == expected do
      true
    else
      Process.sleep(10)
      wait_for_waiters(runtime, expected, attempts - 1)
    end
  end

  test "V2 spawn starts a supervised child Conversation and wait observes its real terminal state" do
    parent = self()

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: "root-collab",
        parent_name: "/root",
        parent_authority: %{
          caller: "host",
          run_id: "root-collab",
          grants: ["spawn_agent", "list_agents", "wait_agent"]
        },
        child_options: &child_options(parent, &1, &2, &3),
        subscriber: parent,
        min_wait_timeout_ms: 0
      )

    tools = ["spawn_agent", "list_agents", "wait_agent"]

    authority = %{
      caller: "host",
      run_id: "root-collab",
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    assert {:ok, profile} =
             Codex.profile(:collaboration_v2, %{collaboration_runtime: runtime}, authority,
               tools: tools
             )

    {:ok, store} = EphemeralStore.new(1)

    {:ok, root} =
      Conversation.start_link(
        run_id: "root-collab",
        store: EphemeralStore,
        context: store,
        provider: RootProvider,
        provider_context: %{test: parent},
        subscriber: parent,
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 20,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(root, "delegate")
    assert_receive {:root_provider, _, root_provider}

    send(root_provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "spawn-1",
            name: "spawn_agent",
            arguments: %{"task_name" => "worker", "message" => "do the task"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "delegating"}}
      ]
    })

    assert_receive {:child_provider, child_run_id, %{messages: child_messages}, child_provider}
    assert String.starts_with?(child_run_id, "/root/worker:")
    assert Enum.any?(child_messages, &(&1[:content] == "do the task"))

    send(child_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "child result"}}]
    })

    assert_receive {:root_provider, %{messages: spawn_messages}, second_root_provider}

    assert %{name: "spawn_agent", result: %{task_name: "/root/worker"}} =
             List.last(spawn_messages)

    send(second_root_provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "list-1", name: "list_agents", arguments: %{}}
        },
        %{
          type: :tool_call_completed,
          tool_call: %{id: "wait-1", name: "wait_agent", arguments: %{"timeout_ms" => 100}}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "checking"}}
      ]
    })

    assert_receive {:root_provider, %{messages: final_messages}, final_root_provider}

    assert Enum.any?(final_messages, fn
             %{name: "list_agents", result: %{agents: [%{agent_name: "/root/worker"}]}} -> true
             _ -> false
           end)

    assert %{name: "wait_agent", result: %{timed_out: false, message: message}} =
             List.last(final_messages)

    assert message =~ "/root/worker"

    send(final_root_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "root-collab", %{type: :run_completed}}
  end

  test "V1 and V2 profiles expose distinct pinned public names" do
    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: "root",
        parent_name: "/root",
        parent_authority: %{caller: "host", run_id: "root", grants: []},
        child_options: fn _, _, _ -> {:error, :unused} end
      )

    v1_tools = [
      "multi_agent_v1::spawn_agent",
      "multi_agent_v1::send_input",
      "multi_agent_v1::resume_agent",
      "multi_agent_v1::wait_agent",
      "multi_agent_v1::close_agent"
    ]

    v1_authority = %{
      caller: "host",
      run_id: "root",
      grants: v1_tools,
      tool_revisions: Map.new(v1_tools, &{&1, 1})
    }

    assert {:ok, v1} =
             Codex.profile(:collaboration_v1, %{collaboration_runtime: runtime}, v1_authority)

    assert Enum.map(v1.tools, & &1.name) == v1_tools

    v2_tools = [
      "spawn_agent",
      "send_message",
      "followup_task",
      "interrupt_agent",
      "list_agents",
      "wait_agent"
    ]

    v2_authority = %{
      caller: "host",
      run_id: "root",
      grants: v2_tools,
      tool_revisions: Map.new(v2_tools, &{&1, 1})
    }

    assert {:ok, v2} =
             Codex.profile(:collaboration_v2, %{collaboration_runtime: runtime}, v2_authority)

    assert Enum.map(v2.tools, & &1.name) == v2_tools
  end

  test "multiple V2 waiters observe the same mailbox update" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{task_name: "/root/worker"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "worker",
               "message" => "wait"
             })

    assert_receive {:child_provider, _run_id, _request, _provider}

    waiter_a =
      Task.async(fn -> call(runtime, :v2, "root", "wait_agent", %{"timeout_ms" => 500}) end)

    waiter_b =
      Task.async(fn -> call(runtime, :v2, "root", "wait_agent", %{"timeout_ms" => 500}) end)

    assert wait_for_waiters(runtime, 2)

    assert {:ok, %{accepted: true}} =
             call(runtime, :v2, "root", "send_message", %{
               "target" => "/root/worker",
               "message" => "update"
             })

    assert {:ok, %{timed_out: false}} = Task.await(waiter_a)
    assert {:ok, %{timed_out: false}} = Task.await(waiter_b)
  end

  test "nested ownership cascades cancellation without stopping a sibling" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{task_name: "/root/parent"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "parent",
               "message" => "parent"
             })

    assert_receive {:child_provider, parent_run_id, _request, _provider}

    assert {:ok, %{task_name: "/root/parent/nested"}} =
             call(runtime, :v2, parent_run_id, "spawn_agent", %{
               "task_name" => "nested",
               "message" => "nested"
             })

    assert_receive {:child_provider, _nested_run_id, _request, _provider}

    assert {:ok, %{task_name: "/root/peer"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "peer",
               "message" => "peer"
             })

    assert_receive {:child_provider, _peer_run_id, _request, _provider}
    before_close = :sys.get_state(runtime)
    peer_pid = before_close.agents["/root/peer"].pid

    assert {:ok, %{status: :interrupted}} =
             call(runtime, :v2, "root", "interrupt_agent", %{"target" => "/root/parent"})

    state = :sys.get_state(runtime)
    assert state.agents["/root/parent"].status == :interrupted
    assert state.agents["/root/parent/nested"].status == :interrupted
    assert state.agents["/root/peer"].status == :running
    assert Process.alive?(peer_pid)
  end

  test "V1 waits reject dependency cycles" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{agent_id: run_a}} =
             call(runtime, :v1, "root", "multi_agent_v1::spawn_agent", %{"message" => "a"})

    assert_receive {:child_provider, ^run_a, _request, _provider}

    assert {:ok, %{agent_id: run_b}} =
             call(runtime, :v1, "root", "multi_agent_v1::spawn_agent", %{"message" => "b"})

    assert_receive {:child_provider, ^run_b, _request, _provider}

    wait_a =
      Task.async(fn ->
        call(runtime, :v1, run_a, "multi_agent_v1::wait_agent", %{
          "targets" => [run_b],
          "timeout_ms" => 500
        })
      end)

    assert wait_for_waiters(runtime, 1)

    assert {:error, %Backplane.AgentRuntime.Error{class: :resource_conflict}} =
             call(runtime, :v1, run_b, "multi_agent_v1::wait_agent", %{
               "targets" => [run_a],
               "timeout_ms" => 500
             })

    assert {:ok, _} =
             call(runtime, :v1, "root", "multi_agent_v1::close_agent", %{"target" => run_b})

    assert {:ok, %{timed_out: false}} = Task.await(wait_a)
  end

  test "completed V2 agent accepts follow-up in a fresh run with prior messages" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{task_name: "/root/worker"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "worker",
               "message" => "first task"
             })

    assert_receive {:child_provider, first_run, first_request, first_provider}
    assert Enum.any?(first_request.messages, &(&1[:content] == "first task"))

    send(
      first_provider,
      {:events,
       [%{type: :response_completed, message: %{role: :assistant, content: "first done"}}]}
    )

    assert {:ok, %{timed_out: false}} =
             call(runtime, :v2, "root", "wait_agent", %{"timeout_ms" => 500})

    assert {:ok, %{accepted: true}} =
             call(runtime, :v2, "root", "followup_task", %{
               "target" => "/root/worker",
               "message" => "second task"
             })

    assert_receive {:child_provider, second_run, second_request, _second_provider}
    refute second_run == first_run

    assert Enum.map(second_request.messages, & &1[:content]) == [
             "first task",
             "first done",
             "second task"
           ]
  end

  test "V1 interrupt-and-send starts a valid replacement run" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{agent_id: first_run}} =
             call(runtime, :v1, "root", "multi_agent_v1::spawn_agent", %{
               "message" => "first task"
             })

    assert_receive {:child_provider, ^first_run, _request, _first_provider}

    assert {:ok, %{submission_id: _}} =
             call(runtime, :v1, "root", "multi_agent_v1::send_input", %{
               "target" => first_run,
               "message" => "replacement task",
               "interrupt" => true
             })

    assert_receive {:child_provider, second_run, second_request, _second_provider}
    refute second_run == first_run
    assert List.last(second_request.messages).content == "replacement task"
  end

  test "V1 close and resume retains completed history without replaying original prompt" do
    {:ok, runtime} = start_runtime(self())

    assert {:ok, %{agent_id: first_run}} =
             call(runtime, :v1, "root", "multi_agent_v1::spawn_agent", %{
               "message" => "write once"
             })

    assert_receive {:child_provider, ^first_run, _request, first_provider}

    send(
      first_provider,
      {:events,
       [%{type: :response_completed, message: %{role: :assistant, content: "done once"}}]}
    )

    assert {:ok, %{timed_out: false}} =
             call(runtime, :v1, "root", "multi_agent_v1::wait_agent", %{
               "targets" => [first_run],
               "timeout_ms" => 500
             })

    assert {:ok, %{status: :shutdown}} =
             call(runtime, :v1, "root", "multi_agent_v1::close_agent", %{"target" => first_run})

    assert {:ok, %{status: :running}} =
             call(runtime, :v1, "root", "multi_agent_v1::resume_agent", %{"id" => first_run})

    refute_receive {:child_provider, _, _, _}, 50

    assert {:ok, %{submission_id: _}} =
             call(runtime, :v1, "root", "multi_agent_v1::send_input", %{
               "target" => first_run,
               "message" => "next task"
             })

    assert_receive {:child_provider, second_run, second_request, _second_provider}
    refute second_run == first_run

    assert Enum.map(second_request.messages, & &1[:content]) == [
             "write once",
             "done once",
             "next task"
           ]
  end

  test "replacement uses a new strict-store revision and rejects old-run calls and events" do
    {:ok, shared_store} = EphemeralStore.new(1)
    test_pid = self()

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: "root",
        parent_name: "/root",
        parent_authority: %{caller: "host", run_id: "root", grants: []},
        child_options: fn request, run_id, parent ->
          {:ok, opts} = child_options(test_pid, request, run_id, parent)
          {:ok, Keyword.put(opts, :context, shared_store)}
        end,
        min_wait_timeout_ms: 0
      )

    assert {:ok, %{task_name: "/root/worker"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "worker",
               "message" => "first"
             })

    assert_receive {:child_provider, first_run, _, first_provider}

    send(
      first_provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert {:ok, %{timed_out: false}} =
             call(runtime, :v2, "root", "wait_agent", %{"timeout_ms" => 500})

    assert {:ok, %{accepted: true}} =
             call(runtime, :v2, "root", "followup_task", %{
               "target" => "/root/worker",
               "message" => "second"
             })

    assert_receive {:child_provider, second_run, request, _}
    refute second_run == first_run
    assert List.last(request.messages).content == "second"
    assert {:ok, %{revision: first_revision}} = EphemeralStore.load(shared_store, first_run)
    assert {:ok, %{revision: second_revision}} = EphemeralStore.load(shared_store, second_run)
    assert first_revision > 1
    assert second_revision > 0

    assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
             call(runtime, :v2, first_run, "list_agents", %{})

    send(runtime, {:agent_runtime, first_run, %{type: :run_failed, outcome: "late"}})

    assert {:ok, %{agents: [%{agent_status: :running}]}} =
             call(runtime, :v2, "root", "list_agents", %{})
  end

  test "lost cancellation settlement refuses replacement execution" do
    {:ok, table} = EphemeralStore.new(1)
    test_pid = self()

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: "root",
        parent_name: "/root",
        parent_authority: %{caller: "host", run_id: "root", grants: []},
        child_options: fn request, run_id, parent ->
          {:ok, opts} = child_options(test_pid, request, run_id, parent)

          {:ok,
           opts |> Keyword.put(:store, FailCleanupStore) |> Keyword.put(:context, %{table: table})}
        end,
        min_wait_timeout_ms: 0
      )

    assert {:ok, %{agent_id: first_run}} =
             call(runtime, :v1, "root", "multi_agent_v1::spawn_agent", %{"message" => "running"})

    assert_receive {:child_provider, ^first_run, _, _}

    assert {:error, %Backplane.AgentRuntime.Error{class: :unknown_outcome}} =
             call(runtime, :v1, "root", "multi_agent_v1::send_input", %{
               "target" => first_run,
               "message" => "must not start",
               "interrupt" => true
             })

    refute_receive {:child_provider, _, %{messages: [%{content: "must not start"}]}, _}, 50
    assert {:ok, %{run: %{state: state}}} = EphemeralStore.load(table, first_run)
    assert state in [:cancelling, :unknown_outcome]
  end

  test "follow-up cannot reset an exhausted child work quota" do
    test_pid = self()

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: "root",
        parent_name: "/root",
        parent_authority: %{caller: "host", run_id: "root", grants: []},
        child_options: fn request, run_id, parent ->
          {:ok, opts} = child_options(test_pid, request, run_id, parent)
          {:ok, Keyword.put(opts, :work, 1)}
        end,
        min_wait_timeout_ms: 0
      )

    assert {:ok, %{task_name: "/root/worker"}} =
             call(runtime, :v2, "root", "spawn_agent", %{
               "task_name" => "worker",
               "message" => "one turn"
             })

    assert_receive {:child_provider, _, _, provider}

    send(
      provider,
      {:events,
       [
         %{type: :response_completed, message: %{role: :assistant, content: "done"}}
       ]}
    )

    assert {:ok, %{timed_out: false}} =
             call(runtime, :v2, "root", "wait_agent", %{"timeout_ms" => 500})

    assert {:error, %Backplane.AgentRuntime.Error{class: :budget_exceeded}} =
             call(runtime, :v2, "root", "followup_task", %{
               "target" => "/root/worker",
               "message" => "another turn"
             })

    refute_receive {:child_provider, _, _, _}, 50
  end

  @tag :tmp_dir
  test "model-callable follow-up retains a committed file mutation without replay", %{
    tmp_dir: root
  } do
    test_pid = self()
    parent_run_id = "root-patch-followup"

    parent_authority = %{
      caller: "host",
      run_id: parent_run_id,
      grants: ["spawn_agent", "followup_task", "apply_patch"],
      tool_revisions: %{"spawn_agent" => 1, "followup_task" => 1, "apply_patch" => 1}
    }

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: parent_run_id,
        parent_name: "/root",
        parent_authority: parent_authority,
        child_options: fn _request, run_id, _parent ->
          child_authority = %{
            caller: "host",
            run_id: run_id,
            grants: ["apply_patch"],
            tool_revisions: %{"apply_patch" => 1}
          }

          {:ok, profile} =
            Codex.profile(:pinned_local, %{workspace: root}, child_authority,
              tools: ["apply_patch"]
            )

          {:ok, child_store} = EphemeralStore.new(1)

          {:ok,
           [
             run_id: run_id,
             store: EphemeralStore,
             context: child_store,
             provider: ChildProvider,
             provider_context: %{test: test_pid},
             registry: profile.registry,
             tools: profile.tools,
             authority: profile.authority,
             schema_admission: :strict,
             work: 10,
             run_timeout: 5_000
           ]}
        end,
        min_wait_timeout_ms: 0
      )

    root_authority = %{
      parent_authority
      | grants: ["spawn_agent", "followup_task"],
        tool_revisions: %{"spawn_agent" => 1, "followup_task" => 1}
    }

    {:ok, root_profile} =
      Codex.profile(:collaboration_v2, %{collaboration_runtime: runtime}, root_authority,
        tools: ["spawn_agent", "followup_task"]
      )

    {:ok, root_store} = EphemeralStore.new(1)

    {:ok, root_conversation} =
      Conversation.start_link(
        run_id: parent_run_id,
        store: EphemeralStore,
        context: root_store,
        provider: RootProvider,
        provider_context: %{test: test_pid},
        subscriber: test_pid,
        registry: root_profile.registry,
        tools: root_profile.tools,
        authority: root_profile.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(root_conversation, "delegate")
    assert_receive {:root_provider, _, root_provider}

    send(
      root_provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "spawn",
             name: "spawn_agent",
             arguments: %{"task_name" => "worker", "message" => "create marker"}
           }
         },
         %{type: :response_completed, message: %{role: :assistant, content: "delegated"}}
       ]}
    )

    assert_receive {:child_provider, first_run, first_request, first_provider}
    assert Enum.any?(first_request.messages, &(&1[:content] == "create marker"))
    patch = "*** Begin Patch\n*** Add File: marker.txt\n+created once\n*** End Patch\n"

    send(
      first_provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "mutation", name: "apply_patch", arguments: patch}
         },
         %{type: :response_completed, message: %{role: :assistant, content: "created"}}
       ]}
    )

    assert_receive {:child_provider, ^first_run, after_patch, next_child_provider}
    assert File.read!(Path.join(root, "marker.txt")) == "created once\n"
    assert Enum.count(after_patch.messages, &(&1[:name] == "apply_patch")) == 1

    send(
      next_child_provider,
      {:events,
       [
         %{
           type: :response_completed,
           message: %{role: :assistant, content: "finished first task"}
         }
       ]}
    )

    assert {:ok, %{timed_out: false}} =
             call(runtime, :v2, parent_run_id, "wait_agent", %{"timeout_ms" => 500})

    assert_receive {:root_provider, _, second_root_provider}

    send(
      second_root_provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "followup",
             name: "followup_task",
             arguments: %{"target" => "/root/worker", "message" => "inspect prior result"}
           }
         },
         %{type: :response_completed, message: %{role: :assistant, content: "continued"}}
       ]}
    )

    assert_receive {:child_provider, second_run, resumed_request, resumed_provider}
    refute second_run == first_run
    assert List.last(resumed_request.messages).content == "inspect prior result"
    assert Enum.count(resumed_request.messages, &(&1[:name] == "apply_patch")) == 1
    assert File.read!(Path.join(root, "marker.txt")) == "created once\n"

    send(
      resumed_provider,
      {:events,
       [
         %{type: :response_completed, message: %{role: :assistant, content: "inspected"}}
       ]}
    )
  end

  @tag :tmp_dir
  test "model-callable V1 interrupt, close, and resume preserve committed mutation", %{
    tmp_dir: root
  } do
    test_pid = self()
    root_run_id = "root-v1-lifecycle"

    v1_tools = [
      "multi_agent_v1::spawn_agent",
      "multi_agent_v1::send_input",
      "multi_agent_v1::close_agent",
      "multi_agent_v1::resume_agent"
    ]

    manager_authority = %{
      caller: "host",
      run_id: root_run_id,
      grants: v1_tools ++ ["apply_patch"]
    }

    {:ok, runtime} =
      MultiAgent.start_link(
        parent_run_id: root_run_id,
        parent_name: "/root",
        parent_authority: manager_authority,
        child_options: fn _request, run_id, _parent ->
          authority = %{
            caller: "host",
            run_id: run_id,
            grants: ["apply_patch"],
            tool_revisions: %{"apply_patch" => 1}
          }

          {:ok, profile} =
            Codex.profile(:pinned_local, %{workspace: root}, authority, tools: ["apply_patch"])

          {:ok, store} = EphemeralStore.new(1)

          {:ok,
           [
             run_id: run_id,
             store: EphemeralStore,
             context: store,
             provider: ChildProvider,
             provider_context: %{test: test_pid},
             registry: profile.registry,
             tools: profile.tools,
             authority: profile.authority,
             schema_admission: :strict,
             work: 15,
             run_timeout: 10_000
           ]}
        end,
        min_wait_timeout_ms: 0
      )

    root_authority = %{
      caller: "host",
      run_id: root_run_id,
      grants: v1_tools,
      tool_revisions: Map.new(v1_tools, &{&1, 1})
    }

    {:ok, profile} =
      Codex.profile(:collaboration_v1, %{collaboration_runtime: runtime}, root_authority,
        tools: v1_tools
      )

    {:ok, store} = EphemeralStore.new(1)

    {:ok, root_conversation} =
      Conversation.start_link(
        run_id: root_run_id,
        store: EphemeralStore,
        context: store,
        provider: RootProvider,
        provider_context: %{test: test_pid},
        subscriber: test_pid,
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 30,
        run_timeout: 10_000
      )

    assert {:ok, _} = Conversation.prompt(root_conversation, "run lifecycle")
    assert_receive {:root_provider, _, root_provider}

    send_root_tool(root_provider, "spawn", "multi_agent_v1::spawn_agent", %{
      "message" => "first task"
    })

    assert_receive {:child_provider, first_run, _, _first_provider}

    assert_receive {:root_provider, _, root_provider}

    send_root_tool(root_provider, "interrupt", "multi_agent_v1::send_input", %{
      "target" => first_run,
      "message" => "make marker",
      "interrupt" => true
    })

    assert_receive {:child_provider, second_run, replacement_request, second_provider}
    refute second_run == first_run
    assert List.last(replacement_request.messages).content == "make marker"

    patch = "*** Begin Patch\n*** Add File: marker.txt\n+one mutation\n*** End Patch\n"

    send(
      second_provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "patch", name: "apply_patch", arguments: patch}
         },
         %{type: :response_completed, message: %{role: :assistant, content: "mutating"}}
       ]}
    )

    assert_receive {:child_provider, ^second_run, _, second_provider}
    assert File.read!(Path.join(root, "marker.txt")) == "one mutation\n"

    send(
      second_provider,
      {:events,
       [
         %{type: :response_completed, message: %{role: :assistant, content: "done marker"}}
       ]}
    )

    assert {:ok, %{timed_out: false, status: %{^first_run => %{completed: "done marker"}}}} =
             call(runtime, :v1, root_run_id, "multi_agent_v1::wait_agent", %{
               "targets" => [second_run],
               "timeout_ms" => 500
             })

    assert_receive {:root_provider, _, root_provider}

    send_root_tool(root_provider, "close", "multi_agent_v1::close_agent", %{"target" => first_run})

    assert_receive {:root_provider, _, root_provider}
    send_root_tool(root_provider, "resume", "multi_agent_v1::resume_agent", %{"id" => first_run})
    assert_receive {:root_provider, _, root_provider}

    send_root_tool(root_provider, "after-resume", "multi_agent_v1::send_input", %{
      "target" => first_run,
      "message" => "inspect prior marker"
    })

    assert_receive {:child_provider, third_run, resumed_request, resumed_provider}
    refute third_run in [first_run, second_run]
    assert List.last(resumed_request.messages).content == "inspect prior marker"
    assert Enum.count(resumed_request.messages, &(&1[:name] == "apply_patch")) == 1
    assert File.read!(Path.join(root, "marker.txt")) == "one mutation\n"

    send(
      resumed_provider,
      {:events,
       [
         %{type: :response_completed, message: %{role: :assistant, content: "inspected"}}
       ]}
    )
  end

  defp send_root_tool(provider, id, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
         %{type: :response_completed, message: %{role: :assistant, content: "continue"}}
       ]}
    )
  end
end
