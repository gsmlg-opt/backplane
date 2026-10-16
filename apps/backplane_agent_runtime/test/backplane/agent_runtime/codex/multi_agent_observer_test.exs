defmodule Backplane.AgentRuntime.Codex.MultiAgentObserverTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, self()})

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
      if elem(meta.command, 0) == :cleanup_settled,
        do: {:error, Error.new(:execution_failure, "cleanup acknowledgement lost")},
        else: EphemeralStore.store(table, run, meta)
    end
  end

  defmodule HeldMutation do
    def execute(operation) do
      context = operation.backend_context
      File.write!(context.marker, "written")
      send(context.test, {:mutation_started, self()})

      receive do
        :release -> {:ok, %{text: "done"}}
      end
    end
  end

  defp start_runtime(options \\ []) do
    test_pid = self()

    start_supervised!(
      {MultiAgent,
       parent_run_id: "root",
       parent_name: "/root",
       parent_authority: %{
         caller: "host",
         run_id: "root",
         grants: Keyword.get(options, :grants, [])
       },
       subscriber: Keyword.get(options, :subscriber),
       max_concurrent_threads_per_session: Keyword.get(options, :max_threads, 4),
       min_wait_timeout_ms: 0,
       child_options: fn request, run_id, context ->
         send(test_pid, {:child_options, request, run_id, context})

         if Keyword.get(options, :reject, false) do
           {:error, Error.new(:forbidden, "birth persistence failed")}
         else
           {:ok, store} = EphemeralStore.new(1)

           {:ok,
            [
              run_id: run_id,
              store: Keyword.get(options, :store, EphemeralStore),
              context: store,
              provider: Provider,
              provider_context: %{test: test_pid},
              registry: Keyword.get(options, :registry, %ToolRegistry{}),
              tools: Keyword.get(options, :tools, []),
              authority: %{
                caller: "host",
                run_id: run_id,
                grants: Keyword.get(options, :grants, []),
                tool_revision: 1
              },
              host_metadata: Keyword.get(options, :host_metadata, %{label: "safe"}),
              schema_admission: :strict,
              work: 10,
              run_timeout: :infinity
            ]}
         end
       end}
    )
  end

  defp call(runtime, tool, arguments, profile \\ :v2, run_id \\ "root") do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: profile},
      run_id: run_id,
      tool_name: tool,
      arguments: arguments
    })
  end

  defp spawn_child(runtime, name \\ "worker") do
    canonical = "/root/" <> name

    assert {:ok, %{task_name: ^canonical}} =
             call(runtime, "spawn_agent", %{"task_name" => name, "message" => "work"})

    assert_receive {:child_options, _, run_id, context}, 1_000
    assert_receive {:provider, ^run_id, provider}, 1_000
    %{name: canonical, run_id: run_id, provider: provider, context: context}
  end

  defp record(runtime, name) do
    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    Enum.find(snapshot.agents, &(&1.name == name))
  end

  defp finish(child, content \\ "done") do
    send(child.provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: content}}]
    })
  end

  defp eventually(check, remaining \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, remaining) do
    if check.() do
      true
    else
      Process.sleep(5)
      eventually(check, remaining - 1)
    end
  end

  defp assert_public(value) do
    assert is_binary(JSON.encode!(value))
    assert safe_term?(value)
  end

  defp safe_term?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, child} ->
        key not in [:pid, :opts, :authority, :grants, :store, :provider, :provider_context] and
          safe_term?(child)
      end)
  end

  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_atom(value)

  defp next_lifecycle_message do
    receive do
      {:codex_collaboration, %{type: type}}
      when type in [
             :admission_reserved,
             :admission_created,
             :admission_rejected,
             :admission_failed
           ] ->
        next_lifecycle_message()

      message ->
        message
    after
      1_000 -> flunk("expected lifecycle event")
    end
  end

  defp discard_admission_events do
    receive do
      {:codex_collaboration, %{type: type}}
      when type in [
             :admission_reserved,
             :admission_created,
             :admission_rejected,
             :admission_failed
           ] ->
        discard_admission_events()
    after
      0 -> :ok
    end
  end

  test "subscription exposes ordered serializable birth and start before provider execution" do
    runtime = start_runtime(host_metadata: %{label: "safe", tracking_id: "ticket"})

    assert {:ok, initial} = MultiAgent.subscribe(runtime)
    assert %{schema_version: 1, root_name: "/root", agents: [], revision: 0} = initial
    assert is_binary(initial.manager_id)

    assert {:ok, %{task_name: "/root/worker"}} =
             call(runtime, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_options, _, run_id, context}
    assert context.run_id == "root"
    assert context.name == "/root"

    assert %{agent_id: agent_id, name: "/root/worker", incarnation: 1, activation: :created} =
             context.child

    next = next_lifecycle_message()
    assert {:codex_collaboration, %{type: :created, agent: created} = birth} = next
    assert created.agent_id == agent_id
    assert created.status == :created
    next = next_lifecycle_message()
    assert {:codex_collaboration, %{type: :started, agent: started} = start} = next
    assert started.status == :running
    assert started.run_id == run_id
    assert start.revision > birth.revision
    assert birth.manager_id == initial.manager_id
    assert start.manager_id == initial.manager_id
    assert_receive {:provider, ^run_id, _provider}

    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    assert snapshot.revision == start.revision
    assert snapshot.agents == [started]
    assert started.task_name == started.name
    assert started.parent_name == "/root"
    assert started.host_metadata == %{label: "safe", tracking_id: "ticket"}

    assert Enum.all?(
             [:parent_id, :profile, :reason, :cleanup, :resident],
             &Map.has_key?(started, &1)
           )

    Enum.each([snapshot, birth, start], &assert_public/1)
  end

  test "host birth callback failure prevents provider execution" do
    runtime = start_runtime(reject: true)
    assert {:ok, _} = MultiAgent.subscribe(runtime)

    assert {:error, %Error{class: :forbidden}} =
             call(runtime, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_options, _, _, %{child: %{activation: :created}}}
    refute_receive {:provider, _, _}, 30
    assert {:ok, %{agents: []}} = MultiAgent.snapshot(runtime)
  end

  test "nonserializable host metadata is rejected before execution" do
    runtime = start_runtime(host_metadata: %{owner: self()})
    assert {:ok, _} = MultiAgent.subscribe(runtime)

    assert {:error, %Error{}} =
             call(runtime, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    refute_receive {:provider, _, _}, 30
    assert {:ok, %{agents: []}} = MultiAgent.snapshot(runtime)
  end

  test "provider failure publishes a serializable terminal reason" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    child = spawn_child(runtime)
    send(child.provider, {:events, [%{type: :response_failed, error: "offline"}]})

    assert_receive {:codex_collaboration, %{type: :settled, agent: failed}}, 1_000
    assert failed.status == :errored
    assert is_binary(failed.reason)
    assert failed.reason != ""
    refute failed.reason =~ "offline"
    assert_public(failed)
    assert_receive {:codex_collaboration, %{type: :result_delivered, agent: delivered}}, 1_000
    assert delivered.result_delivery.status == :accepted
    assert Map.delete(delivered, :result_delivery) == Map.delete(failed, :result_delivery)
    assert record(runtime, child.name) == delivered
  end

  test "follow-up keeps agent identity while replacing run and rejects stale terminal events" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    child = spawn_child(runtime)
    first = record(runtime, child.name)
    finish(child)
    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    assert_receive {:codex_collaboration, %{type: :settled, agent: completed}}
    assert completed.agent_id == first.agent_id

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "again"})

    assert_receive {:child_options, _, next_run, %{child: metadata}}
    assert metadata.agent_id == first.agent_id
    assert metadata.activation == :followup
    assert metadata.incarnation > first.incarnation
    assert_receive {:provider, ^next_run, _}
    current = record(runtime, child.name)
    assert current.agent_id == first.agent_id
    assert current.run_id != first.run_id

    assert {:ok, before_stale} = MultiAgent.snapshot(runtime)

    send(runtime, {
      :agent_runtime,
      first.run_id,
      %{type: :run_failed, run_id: first.run_id, incarnation: first.incarnation, outcome: "stale"}
    })

    send(runtime, {
      :agent_runtime,
      current.run_id,
      %{
        type: :run_failed,
        run_id: current.run_id,
        incarnation: first.incarnation,
        outcome: "stale"
      }
    })

    assert {:ok, after_stale} = MultiAgent.snapshot(runtime)
    assert after_stale == before_stale

    assert {:error, %Error{class: :forbidden}} =
             call(runtime, "list_agents", %{}, :v2, first.run_id)
  end

  test "nested real Conversations expose stable parent links in events and snapshots" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    parent = spawn_child(runtime, "parent")
    parent_record = record(runtime, parent.name)

    assert {:ok, %{task_name: "/root/parent/child"}} =
             call(
               runtime,
               "spawn_agent",
               %{"task_name" => "child", "message" => "nested work"},
               :v2,
               parent.run_id
             )

    assert_receive {:child_options, _, child_run, context}
    assert context.run_id == parent.run_id
    assert context.name == parent.name
    assert context.child.name == "/root/parent/child"
    assert_receive {:provider, ^child_run, _}
    child = record(runtime, "/root/parent/child")
    assert child.parent_id == parent_record.agent_id
    assert child.parent_name == parent_record.name
    assert child.agent_id == context.child.agent_id

    assert_receive {:codex_collaboration,
                    %{type: :created, agent: %{name: "/root/parent/child"} = created}}

    assert created.parent_id == parent_record.agent_id
    assert created.parent_name == parent_record.name
    assert_public(child)
  end

  test "root detach and rebind preserve child parent identity and public revision" do
    runtime = start_runtime()
    _child = spawn_child(runtime)
    assert {:ok, original} = MultiAgent.snapshot(runtime)

    first_binding = %{
      owner_id: "root-session",
      incarnation: 1,
      run_id: "root-turn-1",
      run_incarnation: 1
    }

    authority = %{caller: "host", run_id: first_binding.run_id, grants: []}
    assert :ok = MultiAgent.rebind_parent(runtime, first_binding, authority)
    assert {:ok, after_bind} = MultiAgent.snapshot(runtime)
    assert after_bind == original

    assert :ok = MultiAgent.detach_parent(runtime, first_binding)
    assert {:ok, after_detach} = MultiAgent.snapshot(runtime)
    assert after_detach == original

    next_binding = %{first_binding | run_id: "root-turn-2", run_incarnation: 2}
    next_authority = %{authority | run_id: next_binding.run_id}
    assert :ok = MultiAgent.rebind_parent(runtime, next_binding, next_authority)
    assert {:ok, after_rebind} = MultiAgent.snapshot(runtime)
    assert after_rebind == original
  end

  test "interrupt publishes confirmed target state and keeps its sibling running" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    a = spawn_child(runtime, "a")
    b = spawn_child(runtime, "b")

    assert {:ok, %{status: :interrupted}} =
             call(runtime, "interrupt_agent", %{"target" => a.name})

    assert_receive {:codex_collaboration, %{type: :interrupted, agent: interrupted}}
    assert interrupted.name == a.name
    assert interrupted.status == :interrupted
    assert interrupted.cleanup == :confirmed
    assert record(runtime, b.name).status == :running
  end

  test "lost cancellation acknowledgement publishes cleanup uncertainty" do
    runtime = start_runtime(store: FailCleanupStore)
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    child = spawn_child(runtime)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "interrupt_agent", %{"target" => child.name})

    assert_receive {:codex_collaboration, %{type: :cleanup_uncertain, agent: uncertain}}
    refute uncertain.cleanup == :confirmed
    assert uncertain.status == :unknown_outcome
    assert_public(uncertain)
    assert record(runtime, child.name) == uncertain
  end

  test "V1 close remains observable while model listing hides it" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)

    assert {:ok, %{agent_id: id}} =
             call(runtime, "multi_agent_v1::spawn_agent", %{"message" => "work"}, :v1)

    assert_receive {:provider, _, _}

    assert {:ok, _} =
             call(runtime, "multi_agent_v1::close_agent", %{"target" => id}, :v1)

    assert_receive {:codex_collaboration, %{type: :closed, agent: closed}}
    assert closed.status == :closed
    assert closed.agent_id == id
    assert {:ok, %{agents: []}} = call(runtime, "list_agents", %{})
    assert {:ok, %{agents: [retained]}} = MultiAgent.snapshot(runtime)
    assert retained.agent_id == id
    assert retained.status == :closed
  end

  test "unexpected Conversation exit records uncertainty without inventing cleanup" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    child = spawn_child(runtime)
    pid = :sys.get_state(runtime).agents[child.name].pid
    Process.exit(pid, :kill)

    assert_receive {:codex_collaboration, %{type: :process_exited, agent: exited}}, 1_000
    assert exited.name == child.name
    assert exited.resident == false
    refute exited.cleanup == :confirmed
    assert_public(exited)
  end

  test "idle completed and interrupted Conversation exits publish residency changes" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)

    for state <- [:completed, :interrupted] do
      child = spawn_child(runtime, Atom.to_string(state))

      case state do
        :completed ->
          finish(child)
          assert eventually(fn -> record(runtime, child.name).status == :completed end)

        :interrupted ->
          assert {:ok, %{status: :interrupted}} =
                   call(runtime, "interrupt_agent", %{"target" => child.name})
      end

      assert record(runtime, child.name).resident
      assert {:ok, before_exit} = MultiAgent.snapshot(runtime)
      pid = :sys.get_state(runtime).agents[child.name].pid
      Process.exit(pid, :kill)
      name = child.name

      assert_receive {:codex_collaboration,
                      %{type: :process_exited, agent: %{name: ^name} = exited} = event},
                     1_000

      refute exited.resident
      assert event.revision > before_exit.revision
      assert record(runtime, child.name) == exited
      assert_public(event)
    end
  end

  test "invalid or duplicate spawn leaves a settled resident and revision unchanged" do
    runtime = start_runtime(max_threads: 2)
    child = spawn_child(runtime)
    finish(child)
    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)
    assert hd(before_rejection.agents).resident

    for name <- ["invalid-name", "worker"] do
      assert {:error, %Error{class: :validation}} =
               call(runtime, "spawn_agent", %{"task_name" => name, "message" => "rejected"})

      assert {:ok, after_rejection} = MultiAgent.snapshot(runtime)
      assert after_rejection == before_rejection
    end

    refute_receive {:provider, _, _}, 30
  end

  test "subscribe atomically reconciles completion and unsubscribe stops updates" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    finish(child)
    assert {:ok, initial} = MultiAgent.subscribe(runtime)

    if hd(initial.agents).status == :running do
      assert_receive {:codex_collaboration, %{type: :settled} = event}, 1_000
      assert event.revision > initial.revision
    else
      assert hd(initial.agents).status == :completed
    end

    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    assert :ok = MultiAgent.unsubscribe(runtime)

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "again"})

    assert_receive {:provider, _, _}
    refute_receive {:codex_collaboration, %{type: :started}}, 30

    observer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, _} = MultiAgent.subscribe(runtime, observer)
    ref = Process.monitor(observer)
    send(observer, :stop)
    assert_receive {:DOWN, ^ref, :process, ^observer, :normal}
    assert {:ok, %{agents: [%{status: :running}]}} = MultiAgent.snapshot(runtime)
  end

  test "initial subscriber uses the same unsubscribe interface" do
    runtime = start_runtime(subscriber: self())
    child = spawn_child(runtime)
    assert_receive {:codex_collaboration, %{type: :created}}
    assert_receive {:codex_collaboration, %{type: :started}}
    discard_admission_events()
    assert :ok = MultiAgent.unsubscribe(runtime)
    finish(child)
    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    refute_receive {:codex_collaboration, _}, 30
  end

  test "initial subscriber death removes observation without affecting child execution" do
    observer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    runtime = start_runtime(subscriber: observer)
    child = spawn_child(runtime)
    assert Map.has_key?(:sys.get_state(runtime).observers, observer)
    ref = Process.monitor(observer)
    send(observer, :stop)
    assert_receive {:DOWN, ^ref, :process, ^observer, :normal}
    assert eventually(fn -> not Map.has_key?(:sys.get_state(runtime).observers, observer) end)
    assert record(runtime, child.name).status == :running
    finish(child)
    assert eventually(fn -> record(runtime, child.name).status == :completed end)
  end

  @tag :tmp_dir
  test "V1 process closure retains unresolved mutation uncertainty and its execution slot", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "mutation")
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    assert {:ok, registry} =
             ToolRegistry.register(%ToolRegistry{}, %{
               tool_name: "effect",
               tool_revision: 1,
               description: "held mutation",
               schema: schema,
               safety: %{read_only: false, retry_safe: false, parallel_safe: false},
               backend: HeldMutation,
               backend_context: %{test: self(), marker: marker}
             })

    runtime =
      start_runtime(
        max_threads: 2,
        grants: ["effect"],
        registry: registry,
        tools: [%{name: "effect", description: "held mutation", parameters: schema}]
      )

    assert {:ok, %{agent_id: id}} =
             call(runtime, "multi_agent_v1::spawn_agent", %{"message" => "mutate"}, :v1)

    assert_receive {:child_options, _, run_id, %{child: %{name: name}}}
    assert_receive {:provider, ^run_id, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "mutation", name: "effect", arguments: %{}}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "mutating"}}
      ]
    })

    assert_receive {:mutation_started, worker}, 1_000
    assert File.read!(marker) == "written"
    worker_ref = Process.monitor(worker)

    assert {:ok, %{status: :shutdown}} =
             call(runtime, "multi_agent_v1::close_agent", %{"target" => id}, :v1)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    public = record(runtime, name)
    assert public.status == :unknown_outcome
    assert public.cleanup == :uncertain
    refute public.resident
    assert_public(public)

    cached = :sys.get_state(runtime).agents[name].snapshot
    assert cached.run.state == :unknown_outcome
    assert map_size(cached.run.active_tools) > 0

    assert {:error, %Error{class: :resource_conflict}} =
             call(runtime, "spawn_agent", %{"task_name" => "new", "message" => "blocked"})

    refute_receive {:provider, _, _}, 30
    assert File.read!(marker) == "written"
  end
end
