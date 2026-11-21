defmodule Backplane.AgentRuntime.ReconciliationContinuationColdFixture do
  import ExUnit.Assertions

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Goal, GoalFileStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.CodeMode.{ProcessObserver, Worker}
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Continuation, Evidence}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes

  @source "lost-code-mode-result"
  @scope "same-thread-continuation"
  @root_receipt "lost-code-mode-receipt"

  defmodule Provider do
    def stream(request, ctx) do
      send(ctx.test, {:continuation_provider, request, self()})

      if request.run_id == "lost-code-mode-result" do
        receive do: (:dispatch -> :ok)

        code = """
        const read = tools.fixture__read({value: 1});
        tools.fixture__read({value: 2});
        try { await read; } catch (_) {}
        exit();
        """

        [
          %{
            type: :response_completed,
            usage: %{input_tokens: 50, cached_tokens: 40, output_tokens: 2, reasoning_tokens: 0},
            message: %{
              role: :assistant,
              content: [%{type: :tool_call, id: "lost-exec", name: "exec", arguments: code}]
            }
          }
        ]
      else
        [%{type: :response_completed, message: %{role: :assistant, content: "new turn complete"}}]
      end
    end
  end

  defmodule GoalHost do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: flunk("unexpected automatic Goal continuation")
  end

  defmodule Backend do
    def execute(operation) do
      send(
        operation.backend_context.test,
        {:continuation_read, operation.arguments["value"], self(), operation.invocation_id}
      )

      receive do
        :http_400 ->
          {:error,
           Error.new(:execution_failure, "MCP read rejected", details: %{http_status: 400})}
      end
    end
  end

  def produce(host, dir) do
    assert CodeMode.lifecycle_capability(%{}) == :verified
    config = Host.config(host)

    {:ok, session} =
      Session.start_link(owner_pid: self(), recovery: config, recovery_scope_id: @scope)

    tools = ["exec", "fixture::read"]
    authority = %{caller: "host", run_id: @source, grants: tools, tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority, recovery_store_ref: "source-store")
    goal = goal(dir)

    assert {:ok, _} =
             Goal.set(goal, %{objective: "retain old usage", token_budget: 100}, %{
               text: "retain old usage"
             })

    contract = %{
      name: "read",
      namespace: "fixture",
      backend: Backend,
      backend_context: %{test: self()},
      revision: 1,
      schema: %{
        "type" => "object",
        "required" => ["value"],
        "properties" => %{"value" => %{"type" => "integer"}}
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    assert {:ok, profile} =
             Codex.profile(
               :mixed,
               %{session_binding: binding, code_mode_contracts: [contract]},
               authority,
               tools: tools
             )

    conversation =
      start_run(host, binding, profile.authority, profile.registry, profile.tools, goal, [])

    executor_ref = Process.monitor(conversation)
    assert {:ok, _} = Conversation.prompt(conversation, "do the old reads")
    assert_receive {:continuation_provider, request, provider}, 3_000
    provider_ref = Process.monitor(provider)
    send(provider, :dispatch)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _}, 3_000
    assert_receive {:continuation_read, 1, read, read_id}, 3_000
    assert_receive {:continuation_read, 2, sibling, _}, 3_000
    sibling_ref = Process.monitor(sibling)
    assert {:ok, supervisor} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    assert [{_, worker, :worker, _}] = DynamicSupervisor.which_children(supervisor)
    assert {:ok, %{pid: os_pid}} = Worker.os_identity(worker)
    assert {:ok, %{starttime: starttime}} = ProcessObserver.identity(os_pid)
    worker_ref = Process.monitor(worker)

    send(read, :http_400)
    assert_receive {:DOWN, ^sibling_ref, :process, ^sibling, _}, 3_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3_000
    assert_stopped(os_pid, starttime)

    assert %{state: :unknown_outcome} =
             wait_terminal(conversation, System.monotonic_time(:millisecond) + 5_000)

    GenServer.stop(conversation)
    assert_receive {:DOWN, ^executor_ref, :process, ^conversation, _}, 3_000

    assert {:ok, %{run: run} = original} = Host.load(host, @source)

    assert %{is_error: true, error: %Error{details: %{http_status: 400}}} =
             run.tool_results[read_id]

    assert %{status: :consumed} = run.execution_intents["tool:#{read_id}"]

    [{_, intent}] =
      Enum.filter(run.execution_intents, fn {_, intent} ->
        intent.operation[:tool_name] == "exec"
      end)

    assert intent.status == :uncertain
    refute Map.has_key?(run.tool_results, intent.operation.invocation_id)

    assert {:ok, _} =
             ResourceRegistry.recovery_closed(binding.resource_registry, binding.owner_id)

    assert {:ok, registry} =
             ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id)

    registry_facts = Enum.map(registry["obligations"], &Shapes.observe(&1, "closed"))

    assert {:ok, registry_receipt} =
             reconcile(host, registry, registry_facts, "old-code-registry")

    assert {:ok, manifest} = Session.recovery_manifest(session)
    assert [source] = manifest["run_refs"]

    provider_identity = Map.take(request, ~w(run_id incarnation step_id attempt_id)a)
    {:ok, provider_identity} = Evidence.public(provider_identity)

    facts =
      Enum.flat_map(manifest["obligations"], fn
        %{"kind" => "executor"} = obligation ->
          [Shapes.observe(obligation)]

        %{"kind" => "provider", "identity" => ^provider_identity} = obligation ->
          [Shapes.observe(obligation)]

        %{"kind" => "registry_owner"} = obligation ->
          [
            %{
              Shapes.observe(obligation, "closed")
              | "source_ref" => registry_receipt["receipt_id"]
            }
          ]

        %{"kind" => "tool"} ->
          []
      end)

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile(host, manifest, facts, @root_receipt)

    assert {:ok, root_receipt} = Host.load_receipt(host, @root_receipt)

    assert {:error, %Error{class: :unknown_outcome}} =
             Session.reconcile_close(session, @root_receipt)

    request = %{
      "schema_version" => 1,
      "subject" => manifest["subject"],
      "source" => source,
      "receipt_id" => @root_receipt,
      "closure_evidence_ref" => "cold-closure",
      "instruction_ref" => "click-1"
    }

    proof = %{
      "schema_version" => 1,
      "subject" => request["subject"],
      "source" => source,
      "receipt_digest" => root_receipt["receipt_digest"],
      "components" => %{
        "root_admission" => %{"status" => "admitted", "source_ref" => "root-session-admission"},
        "local_execution" => %{
          "status" => "stopped",
          "source_ref" => "owned-executor-and-deno-joined"
        },
        "async_hooks" => observe_ack("async-hooks"),
        "session_end" => observe_ack("session-end")
      }
    }

    incomplete = put_in(proof, ["components"], Map.delete(proof["components"], "session_end"))
    :ok = Host.put(host, {:evidence, "cold-closure-incomplete"}, incomplete)
    request_missing = %{request | "closure_evidence_ref" => "cold-closure-incomplete"}
    assert {:error, %Error{}} = Continuation.prepare(config, request_missing)
    :ok = Host.put(host, {:evidence, "cold-closure"}, proof)

    assert {:ok, %{goal: %{tokens_used: 12}} = accounting} = Goal.snapshot(goal)

    :ok =
      Host.put(
        host,
        :continuation_fixture,
        {request, request_missing, original, root_receipt, accounting}
      )

    GenServer.stop(goal)
    GenServer.stop(session)
  end

  def consume(host, dir) do
    assert {:ok, {request, request_missing, original, receipt, accounting}} =
             Host.get(host, :continuation_fixture)

    config = Host.config(host)
    goal = goal(dir)
    assert {:error, %Error{}} = Continuation.prepare(config, request_missing)
    assert {:ok, decision} = Continuation.prepare(config, request)
    assert {:ok, ^decision} = Continuation.prepare(config, request)
    assert {:ok, ^accounting} = Goal.snapshot(goal)
    assert Enum.any?(decision["unresolved_tools"], &(&1["tool_call_id"] == "lost-exec"))
    assert receipt["pending"] != []
    %{"run_id" => run_id, "original_incarnation" => incarnation} = decision["target"]
    refute run_id == @source

    {:ok, fresh} =
      Session.start_link(owner_pid: self(), recovery: config, recovery_scope_id: @scope)

    authority = %{caller: "host", run_id: run_id, grants: []}
    assert {:ok, binding} = Session.bind(fresh, authority, incarnation: incarnation)
    refute binding.owner_id == request["subject"]["owner_id"]

    old_history = original.run.context.conversation.messages
    assert Enum.any?(old_history, &(&1.role == :assistant))
    retained_prompts = Enum.filter(old_history, &(&1.role == :user))
    notice = decision["model_notice"]
    messages = retained_prompts ++ [%{role: :user, content: notice}]
    conversation = start_run(host, binding, authority, %ToolRegistry{}, [], goal, messages)
    assert {:ok, _} = Conversation.prompt(conversation, "fresh user work")
    assert_receive {:continuation_provider, %{run_id: ^run_id, messages: projected}, _}, 3_000
    assert Enum.any?(projected, &(&1.content == notice))
    assert Enum.all?(projected, &(&1.role == :user))
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000
    refute_receive {:continuation_read, _, _, _}, 0
    refute_receive {:continuation_provider, %{run_id: @source}, _}, 0
    assert {:ok, ^original} = Host.load(host, @source)
    assert {:ok, ^receipt} = Host.load_receipt(host, @root_receipt)
    assert {:ok, %{goal: %{tokens_used: 12}} = updated} = Goal.snapshot(goal)
    assert updated.goal.goal_id == accounting.goal.goal_id
    assert Map.take(updated.receipts, Map.keys(accounting.receipts)) == accounting.receipts
    GenServer.stop(conversation)
    GenServer.stop(fresh)
    GenServer.stop(goal)
  end

  defp reconcile(host, manifest, facts, id) do
    :ok = Host.put(host, {:evidence, id}, Shapes.bundle(manifest, facts))
    Reconciliation.reconcile(Host.config(host), Shapes.request(manifest, id, id))
  end

  defp goal(dir) do
    {:ok, store} = GoalFileStore.start_link(Path.join(dir, "continuation-accounting"))

    {:ok, goal} =
      Goal.start_link(
        thread_id: @scope,
        owner_pid: self(),
        store: GoalFileStore,
        store_context: store,
        host: GoalHost,
        host_context: nil
      )

    goal
  end

  defp start_run(host, binding, authority, registry, tools, goal, messages) do
    assert {:ok, goal_binding} =
             Goal.bind(goal, %{
               thread_id: @scope,
               run_id: binding.run_id,
               incarnation: binding.run_incarnation,
               authority: authority,
               usage_authoritative: true
             })

    {:ok, pid} =
      Conversation.start_link(
        run_id: binding.run_id,
        incarnation: binding.run_incarnation,
        session_binding: binding,
        store: Host,
        context: host,
        authority: authority,
        registry: registry,
        tools: tools,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        messages: messages,
        goal: goal,
        goal_binding: goal_binding,
        thread_id: @scope,
        effect_timeout: 5_000
      )

    pid
  end

  defp wait_terminal(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: run} ->
        run

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        wait_terminal(conversation, deadline)
    end
  end

  defp observe_ack(component) do
    {worker, ref} = spawn_monitor(fn -> exit({:acknowledged, component}) end)
    assert_receive {:DOWN, ^ref, :process, ^worker, {:acknowledged, ^component}}
    %{"status" => "closed", "source_ref" => component <> "-acknowledged"}
  end

  defp assert_stopped(pid, starttime) do
    case ProcessObserver.identity(pid) do
      {:error, absent} when absent in [:enoent, :esrch] -> :ok
      {:ok, %{starttime: ^starttime, state: state}} -> assert state in ["Z", "X"]
      {:ok, %{starttime: other}} -> assert other != starttime
    end
  end
end
