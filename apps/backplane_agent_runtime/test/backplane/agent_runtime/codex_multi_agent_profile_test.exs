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
end
