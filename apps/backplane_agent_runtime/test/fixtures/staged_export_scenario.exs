Code.require_file("staged_export_host.exs", __DIR__)
Code.require_file("goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.StagedExportScenario do
  import ExUnit.Assertions

  alias Backplane.AgentRuntime.{
    Execution,
    Goal,
    GoalBridge,
    GoalFileStore,
    Kernel,
    Store,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.StagedExportHostFixture, as: Host
  alias Backplane.AgentRuntime.StagedExportFileHostFixture, as: FileHost
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation}

  defmodule GoalHost do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  # Owns the real Goal so asynchronous child admission can request a binding
  # without violating Goal's trusted-owner requirement. Every call reaches Goal.
  defmodule GoalOwner do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      {:ok, goal} = Backplane.AgentRuntime.Goal.start_link(Keyword.put(opts, :owner_pid, self()))
      {:ok, goal}
    end

    def handle_call(request, _from, goal), do: {:reply, GenServer.call(goal, request), goal}

    def terminate(_, goal) do
      if Process.alive?(goal), do: GenServer.stop(goal)
    end
  end

  defmodule GoalProxy do
    use GenServer
    alias Backplane.AgentRuntime.Goal
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:committed, %{type: :turn_stopped} = event}, _from, state) do
      if state.fault == :after_commit, do: assert_committed(state.goal, event)
      send(state.owner, {:goal_held, event})
      {:noreply, state}
    end

    def handle_call({:committed, event}, _, state),
      do: {:reply, Goal.committed(state.goal, event), state}

    def handle_call({:attribution, binding}, _, state),
      do: {:reply, Goal.attribution(state.goal, binding), state}

    def handle_call({:unbind, binding}, _, state),
      do: {:reply, Goal.unbind(state.goal, binding), state}

    defp assert_committed(goal, event) do
      {:ok, _} = Goal.committed(goal, event)
    end
  end

  defmodule Effect do
    def execute(operation) do
      File.write!(
        Path.join(operation.backend_context.dir, "effects"),
        operation.backend_context.label <> "\n",
        [:append]
      )

      {:ok, %{value: "once"}}
    end
  end

  def manager(host, dir, label, goal_options \\ []) do
    {:ok, manager} =
      MultiAgent.start_link(
        parent_run_id: "root-#{label}",
        parent_name: "/root",
        parent_authority: %{
          caller: "host",
          run_id: "root-#{label}",
          grants: ["effect"],
          tool_revision: 1
        },
        root_agent_id: "stable-root",
        recovery_scope_id: "scope",
        recovery: Host.config(host),
        min_wait_timeout_ms: 0,
        child_options: fn request, run_id, parent ->
          {:ok, options} = Host.child_options(host, label, request, run_id, parent)

          {:ok, registry} =
            ToolRegistry.register(%ToolRegistry{}, %{
              tool_name: "effect",
              tool_revision: 1,
              description: "count effect",
              backend: Effect,
              backend_context: %{dir: dir, label: label},
              schema: %{"type" => "object", "properties" => %{}},
              safety: %{read_only: false, retry_safe: false, parallel_safe: false}
            })

          authority = %{caller: "host", run_id: run_id, grants: ["effect"], tool_revision: 1}

          goal_options =
            case goal_options do
              [] ->
                []

              [goal: goal, proxy: proxy] ->
                {:ok, binding} =
                  Goal.bind(goal, %{
                    thread_id: "thread",
                    run_id: run_id,
                    incarnation: parent.child.incarnation,
                    authority: authority,
                    usage_authoritative: true
                  })

                [goal: proxy, goal_binding: binding, thread_id: "thread"]
            end

          {:ok,
           Keyword.merge(
             options,
             [
               name: {:global, {__MODULE__, run_id}},
               registry: registry,
               tools: [
                 %{
                   name: "effect",
                   description: "count effect",
                   parameters: %{"type" => "object", "properties" => %{}}
                 }
               ],
               authority: authority
             ] ++ goal_options
           )}
        end
      )

    manager
  end

  def source(dir, fault) do
    host = Host.new(self(), dir: Path.join(dir, "runtime"))
    {goal_store, goal} = goal(dir)

    {:ok, _} =
      Goal.set(goal, %{objective: "keep exact accounting", token_budget: 100}, %{text: "work"})

    {:ok, proxy} = GoalProxy.start_link(%{owner: self(), goal: goal, fault: fault})
    manager = manager(host, dir, "source", goal: goal, proxy: proxy)

    assert {:ok, _} =
             call(manager, "source", "spawn_agent", %{"task_name" => "child", "message" => "work"})

    assert_receive {:provider, "source", request, provider}, 1_000
    provider_monitor = Process.monitor(provider)

    send(
      provider,
      {:events,
       [
         %{
           type: :response_completed,
           message: %{
             role: :assistant,
             content: [%{type: :tool_call, id: "effect", name: "effect", arguments: %{}}]
           }
         }
       ]}
    )

    assert_receive {:provider, "source", _next, final_provider}, 1_000
    final_monitor = Process.monitor(final_provider)

    send(
      final_provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert_receive {:goal_held, event}, 1_000
    assert {:ok, goal_snapshot} = Goal.snapshot(goal)
    assert Map.has_key?(goal_snapshot.receipts, event.receipt_id) == (fault == :after_commit)

    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}, 1_000
    assert_receive {:DOWN, ^final_monitor, :process, ^final_provider, :normal}, 1_000

    # Conversation drains Goal before cancelling, so a held Goal cannot itself
    # supply an archive-eligible terminal run. The trusted host first retires the
    # exact executor, observes its exit, fences Store, and commits ordinary Kernel
    # cancellation with the authoritative empty cleanup inventory. No tool result,
    # Goal acknowledgement or retirement receipt is synthesized by this recovery.
    executor = :global.whereis_name({__MODULE__, request.run_id})
    assert is_pid(executor)
    executor_monitor = Process.monitor(executor)
    GenServer.stop(executor)
    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :normal}, 1_000
    assert {:ok, before} = FileHost.load(host.store, request.run_id)
    assert before.run.state == :running

    assert Kernel.cleanup_requirements(before.run) == %{
             provider: nil,
             tools: [],
             children: [],
             dependencies: []
           }

    assert {:ok, fenced} =
             Store.fence(
               FileHost,
               host.store,
               request.run_id,
               before.revision,
               before.run.incarnation,
               before.run.incarnation + 1
             )

    commit(host, fenced.run, {:cancel, 100})
    assert {:ok, cancelling} = FileHost.load(host.store, request.run_id)

    commit(
      host,
      cancelling.run,
      {:cleanup_settled, 101,
       %{certainty: :confirmed, settled: Kernel.cleanup_requirements(cancelling.run)}}
    )

    source_chain = [
      %{
        "run_id" => request.run_id,
        "from_revision" => before.revision,
        "to_revision" => before.revision + 1,
        "from_incarnation" => before.run.incarnation,
        "to_incarnation" => before.run.incarnation + 1,
        "source_ref" => "observed-source-executor-exit"
      }
    ]

    {:ok, snapshot} = MultiAgent.snapshot(manager)
    agent = hd(snapshot.agents)
    {:ok, record} = FileHost.load(host.store, agent.run_id)
    assert record.run.state == :cancelled
    assert record.run.context.conversation.goal_outbox != []
    assert event.run_id == request.run_id
    Host.seal_inventory(host, agent)
    assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, agent.name)

    %{
      host: host,
      manager: manager,
      agent: agent,
      manifest: manifest,
      goal: goal,
      goal_store: goal_store,
      proxy: proxy,
      source_chain: source_chain,
      dir: dir
    }
  end

  def goal(dir) do
    {:ok, store} = GoalFileStore.start_link(Path.join(dir, "goal"))

    {:ok, goal} =
      GoalOwner.start_link(
        thread_id: "thread",
        store: GoalFileStore,
        store_context: store,
        host: GoalHost,
        host_context: nil
      )

    {store, goal}
  end

  def acknowledge(ctx) do
    {:ok, record} = FileHost.load(ctx.host.store, ctx.agent.run_id)

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: ctx.agent.run_id,
        incarnation: ctx.agent.incarnation,
        authority: %{caller: "host", run_id: ctx.agent.run_id, grants: []},
        usage_authoritative: true
      })

    assert {:ok, _} = GoalBridge.redeliver(ctx.goal, binding, record.run)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert {:ok, _} = GoalBridge.redeliver(ctx.goal, binding, record.run)
    assert {:ok, ^snapshot} = Goal.snapshot(ctx.goal)

    command =
      {:goal_outbox_acknowledged, 100,
       %{
         run_id: ctx.agent.run_id,
         incarnation: record.run.incarnation,
         receipts: record.run.context.conversation.goal_outbox
       }}

    assert {:ok, _} = Store.store(FileHost, ctx.host.store, record.run, %{command: command})
  end

  def receipt(ctx, revision \\ 0, chain \\ []) do
    ref = "bundle:#{revision}"

    bundle =
      Host.bundle(ctx.manifest) |> Map.put("run_fences", Map.get(ctx, :source_chain, []) ++ chain)

    assert :ok = Host.put(ctx.host, {:evidence, ref}, bundle)

    request =
      Shapes.request(ctx.manifest, "retired", ref) |> Map.put("expected_revision", revision)

    assert {:ok, _} = Reconciliation.reconcile(Host.config(ctx.host), request)
    "retired"
  end

  defp commit(host, run, command) do
    assert {:ok, _, _} =
             Execution.commit(FileHost, host.store, run, %{command: command},
               run_timeout: :infinity
             )
  end

  def call(manager, label, tool, args, profile \\ :v2),
    do:
      MultiAgent.call(%{
        backend_context: %{runtime: manager, profile: profile},
        run_id: "root-#{label}",
        tool_name: tool,
        arguments: args
      })
end
