defmodule Backplane.AgentRuntime.Codex.MultiAgentV2LifecycleTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  @tools ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, request, self()})

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

    def store(table, run, meta) do
      if elem(meta.command, 0) == :cleanup_settled do
        {:error, Error.new(:execution_failure, "cleanup acknowledgement lost")}
      else
        EphemeralStore.store(table, run, meta)
      end
    end
  end

  defp start_runtime(opts \\ []) do
    test_pid = self()
    catalog = :ets.new(:collaboration_catalog, [:set, :public])

    runtime =
      start_supervised!(
        {MultiAgent,
         [
           parent_run_id: "root",
           parent_name: "/root",
           parent_authority: authority("root"),
           min_wait_timeout_ms: 0,
           child_options: fn _request, run_id, _parent ->
             {:ok, store} = EphemeralStore.new(1)

             [{:profile, profile}] = :ets.lookup(catalog, :profile)

             {:ok,
              [
                run_id: run_id,
                store: Keyword.get(opts, :store, EphemeralStore),
                context: store,
                provider: Provider,
                provider_context: %{test: test_pid},
                registry: profile.registry,
                tools: profile.tools,
                authority: authority(run_id),
                schema_admission: :strict,
                work: 30,
                run_timeout: :infinity
              ]}
           end
         ] ++ Keyword.take(opts, [:max_agents, :max_concurrent_threads_per_session])}
      )

    {:ok, profile} =
      Codex.profile(
        :collaboration_v2,
        %{collaboration_runtime: runtime},
        authority("root"),
        tools: @tools
      )

    :ets.insert(catalog, {:profile, profile})
    runtime
  end

  defp authority(run_id) do
    %{
      caller: "host",
      run_id: run_id,
      grants: @tools,
      tool_revisions: Map.new(@tools, &{&1, 1})
    }
  end

  defp call(runtime, tool, args, run_id \\ "root") do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: :v2},
      run_id: run_id,
      tool_name: tool,
      arguments: args
    })
  end

  defp spawn_agent(runtime, name) do
    canonical = "/root/" <> name

    assert {:ok, %{task_name: ^canonical}} =
             call(runtime, "spawn_agent", %{"task_name" => name, "message" => name})

    assert_receive {:provider, run_id, request, provider}, 1_000
    %{name: canonical, run_id: run_id, request: request, provider: provider}
  end

  defp complete(runtime, agent, message \\ "done") do
    send(agent.provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: message}}]
    })

    assert eventually(fn -> statuses(runtime)[agent.name] == %{completed: message} end)
  end

  defp statuses(runtime) do
    assert {:ok, %{agents: agents}} = call(runtime, "list_agents", %{})
    Map.new(agents, &{&1.agent_name, &1.agent_status})
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end

  defp residents(runtime) do
    runtime
    |> :sys.get_state()
    |> Map.fetch!(:child_supervisor)
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  test "V2 interrupts only A's current task while admitted nested B and sibling C continue" do
    runtime = start_runtime()
    a = spawn_agent(runtime, "a")

    send(a.provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "nested",
            name: "spawn_agent",
            arguments: %{"task_name" => "b", "message" => "independent nested work"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "delegating"}}
      ]
    })

    a_run = a.run_id
    assert_receive {:provider, ^a_run, _, _a_next_provider}, 1_000
    assert_receive {:provider, b_run, _, b_provider}, 1_000
    c = spawn_agent(runtime, "c")

    assert {:ok, %{status: :interrupted}} =
             call(runtime, "interrupt_agent", %{"target" => a.name})

    assert statuses(runtime) == %{
             "/root/a" => :interrupted,
             "/root/a/b" => :running,
             "/root/c" => :running
           }

    assert Process.alive?(b_provider)
    assert Process.alive?(c.provider)

    assert {:ok, %{previous_status: :interrupted, status: :interrupted}} =
             call(runtime, "interrupt_agent", %{"target" => a.name})

    assert statuses(runtime)["/root/a/b"] == :running
    complete(runtime, %{name: "/root/a/b", run_id: b_run, provider: b_provider}, "nested done")
    complete(runtime, c, "sibling done")
    assert :ok = MultiAgent.close_session(runtime)
    assert residents(runtime) == 0
  end

  test "V2 rejects root and self interruption without cancelling a current task" do
    runtime = start_runtime()
    a = spawn_agent(runtime, "a")

    for target <- ["/root", "root"] do
      assert {:error, %Error{}} = call(runtime, "interrupt_agent", %{"target" => target})
    end

    assert {:error, %Error{class: :forbidden}} =
             call(runtime, "interrupt_agent", %{"target" => a.name}, a.run_id)

    assert statuses(runtime)[a.name] == :running
    assert Process.alive?(a.provider)
  end

  test "interrupting completed V2 identity preserves its prior status and does not reload it" do
    runtime = start_runtime(max_agents: 1)
    a = spawn_agent(runtime, "a")
    complete(runtime, a, "retained result")
    before = residents(runtime)

    assert {:ok, %{previous_status: %{completed: "retained result"}}} =
             call(runtime, "interrupt_agent", %{"target" => a.name})

    assert statuses(runtime)[a.name] == %{completed: "retained result"}
    assert residents(runtime) == before
    refute_receive {:provider, _, _, _}, 20
  end

  test "one V2 execution slot admits B after A and reuses A with committed history" do
    runtime = start_runtime(max_agents: 1)
    a = spawn_agent(runtime, "a")
    complete(runtime, a, "first result")
    b = spawn_agent(runtime, "b")
    assert statuses(runtime)[a.name] == %{completed: "first result"}
    complete(runtime, b, "second result")

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => a.name, "message" => "follow up"})

    assert_receive {:provider, next_run, request, provider}, 1_000
    refute next_run == a.run_id
    assert Enum.map(request.messages, & &1[:content]) == ["a", "first result", "follow up"]
    assert map_size(statuses(runtime)) == 2
    complete(runtime, %{a | run_id: next_run, provider: provider}, "follow-up result")
  end

  test "many sequential completed V2 identities retain history with bounded child processes" do
    runtime = start_runtime(max_agents: 1)

    for index <- 1..12 do
      a = spawn_agent(runtime, "agent_#{index}")
      complete(runtime, a, "result #{index}")
      assert residents(runtime) <= 1
    end

    assert map_size(statuses(runtime)) == 12
    assert Enum.all?(statuses(runtime), fn {_name, status} -> match?(%{completed: _}, status) end)
    assert :ok = MultiAgent.close_session(runtime)
    assert residents(runtime) == 0
  end

  test "concurrent follow-up admissions and nested creation share the same V2 execution slot" do
    runtime = start_runtime(max_agents: 1)
    a = spawn_agent(runtime, "a")
    complete(runtime, a)
    b = spawn_agent(runtime, "b")
    complete(runtime, b)

    results =
      for agent <- [a, b] do
        Task.async(fn ->
          call(runtime, "followup_task", %{"target" => agent.name, "message" => "activate"})
        end)
      end
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %{accepted: true}}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Error{class: :resource_conflict}}, &1)) == 1
    assert_receive {:provider, active_run, _, provider}, 1_000
    assert Enum.count(statuses(runtime), fn {_name, status} -> status == :running end) == 1

    assert {:error, %Error{class: :resource_conflict}} =
             call(
               runtime,
               "spawn_agent",
               %{"task_name" => "nested", "message" => "nested"},
               active_run
             )

    assert Process.alive?(provider)
    assert residents(runtime) <= 1
  end

  test "lost cleanup acknowledgement keeps the V2 slot reserved and refuses replacement" do
    runtime = start_runtime(max_agents: 1, store: FailCleanupStore)
    a = spawn_agent(runtime, "a")

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "interrupt_agent", %{"target" => a.name})

    assert {:error, %Error{class: :resource_conflict}} =
             call(runtime, "spawn_agent", %{"task_name" => "b", "message" => "must not start"})

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "followup_task", %{"target" => a.name, "message" => "must not restart"})

    refute_receive {:provider, _, _, _}, 20
    assert Map.has_key?(statuses(runtime), a.name)
  end

  test "V2 session concurrency includes the root and defaults to four total threads" do
    root_only = start_runtime(max_concurrent_threads_per_session: 1)

    assert {:error, %Error{class: :resource_conflict}} =
             call(root_only, "spawn_agent", %{"task_name" => "a", "message" => "work"})

    assert residents(root_only) == 0
    stop_supervised!(MultiAgent)

    one_child = start_runtime(max_concurrent_threads_per_session: 2, max_agents: 8)
    a = spawn_agent(one_child, "a")

    assert {:error, %Error{class: :resource_conflict}} =
             call(one_child, "spawn_agent", %{"task_name" => "b", "message" => "work"})

    complete(one_child, a)
    spawn_agent(one_child, "b")
    stop_supervised!(MultiAgent)

    default = start_runtime()
    for name <- ["a", "b", "c"], do: spawn_agent(default, name)

    assert {:error, %Error{class: :resource_conflict}} =
             call(default, "spawn_agent", %{"task_name" => "d", "message" => "work"})
  end

  test "invalid collaboration capacity configuration is rejected before child execution" do
    for config <- [
          [max_concurrent_threads_per_session: 0],
          [max_concurrent_threads_per_session: "four"],
          [max_agents: 0],
          [max_agents: :infinity]
        ] do
      assert {:error, _} =
               MultiAgent.start_link(
                 [
                   parent_run_id: "root",
                   parent_name: "/root",
                   parent_authority: authority("root"),
                   child_options: fn _, _, _ ->
                     send(self(), :unexpected_child)
                     {:error, :unused}
                   end
                 ] ++ config
               )
    end

    refute_receive :unexpected_child, 20
  end

  test "V1 completed identity still occupies max_agents until explicit close" do
    runtime = start_runtime(max_agents: 1)

    v1_call = fn tool, args ->
      MultiAgent.call(%{
        backend_context: %{runtime: runtime, profile: :v1},
        run_id: "root",
        tool_name: "multi_agent_v1::" <> tool,
        arguments: args
      })
    end

    assert {:ok, %{agent_id: first}} = v1_call.("spawn_agent", %{"message" => "first"})
    assert_receive {:provider, ^first, _, provider}
    name = first |> String.split(":") |> hd()
    complete(runtime, %{name: name, provider: provider}, "V1 done")

    assert {:error, %Error{class: :resource_conflict}} =
             v1_call.("spawn_agent", %{"message" => "second"})

    assert {:ok, %{status: :shutdown}} = v1_call.("close_agent", %{"target" => first})
    assert {:ok, %{agent_id: second}} = v1_call.("spawn_agent", %{"message" => "second"})
    assert_receive {:provider, ^second, _, _}
  end

  test "safely failed V2 child releases execution capacity and accepts follow-up" do
    runtime = start_runtime(max_agents: 1)
    a = spawn_agent(runtime, "a")
    send(a.provider, {:events, [%{type: :response_failed, error: "offline"}]})
    assert eventually(fn -> match?(%{errored: _}, statuses(runtime)[a.name]) end)
    b = spawn_agent(runtime, "b")
    complete(runtime, b)

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => a.name, "message" => "retry"})

    assert_receive {:provider, next_run, _, _}
    refute next_run == a.run_id
    assert map_size(statuses(runtime)) == 2
  end

  test "V2 interruption leaves a safely completed V1 identity unchanged" do
    runtime = start_runtime(max_agents: 1)

    assert {:ok, %{agent_id: run_id}} =
             MultiAgent.call(%{
               backend_context: %{runtime: runtime, profile: :v1},
               run_id: "root",
               tool_name: "multi_agent_v1::spawn_agent",
               arguments: %{"message" => "legacy"}
             })

    assert_receive {:provider, ^run_id, _, provider}
    name = run_id |> String.split(":") |> hd()
    complete(runtime, %{name: name, provider: provider}, "legacy done")
    before = statuses(runtime)

    assert {:ok, %{status: %{completed: "legacy done"}}} =
             call(runtime, "interrupt_agent", %{"target" => name})

    assert statuses(runtime) == before
    assert Process.alive?(runtime)
  end

  test "a current-run lifecycle envelope without incarnation cannot invent interruption" do
    runtime = start_runtime(max_agents: 1)
    a = spawn_agent(runtime, "a")
    send(runtime, {:agent_runtime, a.run_id, %{type: :run_cancelled, run_id: a.run_id}})
    complete(runtime, a, "actual completion")
    assert statuses(runtime)[a.name] == %{completed: "actual completion"}
  end

  test "V2 follow-up of a V1-born identity shares the executing session budget" do
    runtime = start_runtime(max_concurrent_threads_per_session: 2)

    assert {:ok, %{agent_id: run_id}} =
             MultiAgent.call(%{
               backend_context: %{runtime: runtime, profile: :v1},
               run_id: "root",
               tool_name: "multi_agent_v1::spawn_agent",
               arguments: %{"message" => "legacy"}
             })

    assert_receive {:provider, ^run_id, _, provider}
    name = run_id |> String.split(":") |> hd()
    complete(runtime, %{name: name, provider: provider}, "legacy done")
    b = spawn_agent(runtime, "b")

    assert {:error, %Error{class: :resource_conflict}} =
             call(runtime, "followup_task", %{"target" => name, "message" => "legacy again"})

    complete(runtime, b)

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => name, "message" => "legacy again"})

    assert_receive {:provider, next_run, request, _}
    refute next_run == run_id
    assert Enum.map(request.messages, & &1[:content]) == ["legacy", "legacy done", "legacy again"]
  end
end
