defmodule Backplane.AgentRuntime.ConversationMultiAgentRejectionsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, context.role, request, self()})

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

  test "V2 capacity rejection continues its real parent without preparing a fourth child" do
    {runtime, parent, store} = start_conversation()
    assert {:ok, _} = Conversation.prompt(parent, "delegate work")
    assert_receive {:provider, :parent, _, provider}, 1_000

    {provider, children} =
      Enum.reduce(1..3, {provider, []}, fn index, {provider, children} ->
        name = "child_#{index}"
        canonical = "/root/" <> name
        call_id = "spawn-#{index}"
        spawn_from(provider, name, call_id)

        assert_receive {:child_preparation, %{task_name: ^name}, run_id}, 1_000
        assert_receive {:admission_receipt, %{status: :created, run_id: ^run_id}}, 1_000
        assert_receive {:provider, :child, %{run_id: ^run_id}, child_provider}, 1_000
        assert_receive {:provider, :parent, request, next_provider}, 1_000

        assert %{tool_call_id: ^call_id, result: %{task_name: ^canonical}} =
                 List.last(request.messages)

        {next_provider, [child_provider | children]}
      end)

    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)
    assert length(before_rejection.agents) == 3
    assert length(before_rejection.admissions) == 3
    assert Enum.all?(before_rejection.agents, &(&1.status == :running))

    spawn_from(provider, "child_4", "spawn-4")

    assert_receive {:provider, :parent, request, next_provider}, 1_000

    assert %{
             role: :tool,
             name: "spawn_agent",
             tool_call_id: "spawn-4",
             result: %{is_error: true, error: %Error{class: :resource_conflict}}
           } = List.last(request.messages)

    assert {:ok, after_rejection} = MultiAgent.snapshot(runtime)
    assert after_rejection.agents == before_rejection.agents
    assert after_rejection.admissions == before_rejection.admissions
    assert Enum.all?(children, &Process.alive?/1)
    refute_receive {:child_preparation, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
    refute_receive {:provider, :child, _, _}, 20
    refute_receive {:agent_runtime, _, %{type: :run_cancelled}}, 20

    assert {:ok, %{run: run}} = EphemeralStore.load(store, "root")
    assert run.active_tools == %{}
    refute run.state == :unknown_outcome

    send(next_provider, {:events, [done("capacity handled")]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    assert Conversation.status(parent).run.state == :completed
    assert Enum.all?(children, &Process.alive?/1)
  end

  defp start_conversation do
    test = self()
    tools = ["spawn_agent"]

    authority = %{
      caller: "host",
      run_id: "root",
      grants: tools,
      tool_revisions: %{"spawn_agent" => 1}
    }

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: authority,
         max_concurrent_threads_per_session: 4,
         child_options: fn request, run_id, _parent ->
           send(test, {:child_preparation, request, run_id})
           {:ok, child_store} = EphemeralStore.new(1)

           {:ok,
            [
              run_id: run_id,
              store: EphemeralStore,
              context: child_store,
              provider: Provider,
              provider_context: %{test: test, role: :child},
              registry: %ToolRegistry{},
              tools: [],
              authority: %{caller: "host", run_id: run_id, grants: []},
              schema_admission: :strict,
              work: 10,
              run_timeout: :infinity
            ]}
         end,
         admission_receipt: fn receipt ->
           send(test, {:admission_receipt, receipt})
           :ok
         end}
      )

    {:ok, profile} =
      Codex.profile(:collaboration_v2, %{collaboration_runtime: runtime}, authority, tools: tools)

    {:ok, store} = EphemeralStore.new(1)

    parent =
      start_supervised!(
        {Conversation,
         run_id: "root",
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: test, role: :parent},
         subscriber: test,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         work: 40,
         run_timeout: :infinity}
      )

    {runtime, parent, store}
  end

  defp spawn_from(provider, name, call_id) do
    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: call_id,
            name: "spawn_agent",
            arguments: %{"task_name" => name, "message" => "hold this child open"}
          }
        },
        done("delegating")
      ]
    })
  end

  defp done(content),
    do: %{type: :response_completed, message: %{role: :assistant, content: content}}
end
