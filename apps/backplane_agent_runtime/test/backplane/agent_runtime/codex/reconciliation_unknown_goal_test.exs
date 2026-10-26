Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)
Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)
Code.require_file("../../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationUnknownGoalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error, Goal, GoalFileStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule GoalHost do
    def record_user_instruction(test, thread, instruction) do
      send(test, {:goal_host_instruction, thread, instruction})
      :ok
    end

    def start_turn_if_idle(test, thread, request) do
      send(test, {:goal_host_admission, thread, request})
      {:ok, {:not_submitted, :busy}}
    end
  end

  # Count actual public Goal operations, including idempotent redeliveries that
  # would leave its persisted snapshot unchanged. No Goal responses are fabricated.
  defmodule GoalProxy do
    use GenServer

    def start_link(goal), do: GenServer.start_link(__MODULE__, goal)
    def calls(proxy), do: GenServer.call(proxy, :calls)
    def init(goal), do: {:ok, %{goal: goal, calls: []}}
    def handle_call(:calls, _, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:attribution, binding} = request, _, state),
      do: reply(state, request, Goal.attribution(state.goal, binding))

    def handle_call({:committed, event} = request, _, state),
      do: reply(state, request, Goal.committed(state.goal, event))

    def handle_call({:unbind, binding} = request, _, state),
      do: reply(state, request, Goal.unbind(state.goal, binding))

    defp reply(state, request, result),
      do: {:reply, result, %{state | calls: [request | state.calls]}}
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider_started, request, self()})

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

  test "reconciling a cancelled root closes its lifetime without changing unknown outcome or Goal",
       context do
    {:ok, host} = Host.open(Path.join(context.tmp_dir, "runtime"))
    on_exit(fn -> Host.cleanup(host) end)
    goal_store = start_supervised!({GoalFileStore, Path.join(context.tmp_dir, "goal")})
    id = "unknown-goal-root"
    thread = "unknown-goal-thread"
    authority = %{caller: "host", run_id: id, grants: []}

    goal =
      start_supervised!(
        {Goal,
         thread_id: thread,
         owner_pid: self(),
         store: GoalFileStore,
         store_context: goal_store,
         host: GoalHost,
         host_context: self()}
      )

    assert {:ok, _} =
             Goal.set(goal, %{objective: "retain actual accounting", token_budget: 100}, %{
               text: "retain actual accounting"
             })

    assert_receive {:goal_host_instruction, ^thread, %{text: "retain actual accounting"}}

    session =
      start_supervised!(
        {Session,
         owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "unknown-goal"}
      )

    {:ok, binding} = Session.bind(session, authority, recovery_store_ref: "source-store")

    {:ok, goal_binding} =
      Goal.bind(goal, %{
        thread_id: thread,
        run_id: id,
        incarnation: 1,
        authority: authority,
        usage_authoritative: true
      })

    proxy = start_supervised!({GoalProxy, goal})

    component =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> :owned_resource end}, restart: :temporary)
      )

    component_monitor = Process.monitor(component)
    test = self()

    {:ok, handle} =
      ResourceRegistry.register(
        binding.resource_registry,
        binding.owner_id,
        :component,
        component,
        owner_pid: session,
        incarnation: binding.incarnation,
        cleanup: fn ->
          send(test, :cleanup_called)
          Agent.stop(component)
          {:uncertain, :lost_cleanup_ack}
        end
      )

    conversation =
      start_supervised!(%{
        id: Conversation,
        restart: :temporary,
        start:
          {Conversation, :start_link,
           [
             [
               run_id: id,
               incarnation: 1,
               session_binding: binding,
               store: Host,
               context: host,
               provider: Provider,
               provider_context: %{test: self()},
               subscriber: self(),
               registry: %ToolRegistry{},
               tools: [],
               authority: authority,
               goal: proxy,
               goal_binding: goal_binding,
               thread_id: thread,
               work: 10,
               run_timeout: :infinity
             ]
           ]}
      })

    executor_monitor = Process.monitor(conversation)
    assert {:ok, _} = Conversation.prompt(conversation, "work once")
    assert_receive {:provider_started, request, provider}, 1_000
    provider_monitor = Process.monitor(provider)
    provider_identity = Map.take(request, [:run_id, :incarnation, :step_id, :attempt_id])
    usage = %{input_tokens: 50, cached_tokens: 40, output_tokens: 2, reasoning_tokens: 0}
    send(provider, {:events, [%{type: :usage_updated, usage: usage}]})
    assert_receive {:agent_runtime, ^id, %{type: :usage_updated}}, 1_000
    assert {:ok, %{goal: %{tokens_used: 12}, remaining_tokens: 88}} = Goal.get(goal)

    assert :ok = Conversation.cancel(conversation)
    assert_receive :cleanup_called, 1_000
    assert_receive {:DOWN, ^component_monitor, :process, ^component, :normal}, 1_000
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, _}, 1_000

    assert_receive {:agent_runtime, ^id, %{type: :run_cancelled, state: :unknown_outcome}},
                   1_000

    assert %{phase: :terminal, run: %{state: :unknown_outcome}} =
             Conversation.status(conversation)

    assert %{phase: :closed, initial_cleanup: {:error, %Error{class: :unknown_outcome}}} =
             initial_status = Session.status(session)

    GenServer.stop(conversation)
    assert_receive {:DOWN, ^executor_monitor, :process, ^conversation, :normal}, 1_000
    drain_runtime_events(id)

    {:ok, authoritative} = Host.load(host, id)
    assert authoritative.run.incarnation == 1
    assert authoritative.run.state == :unknown_outcome
    assert authoritative.run.outcome["cleanup"]["certainty"] == "uncertain"
    assert authoritative.run.context.conversation.goal_outbox == []
    assert Enum.any?(Map.values(authoritative.run.provider_attempts), &(&1 == provider_identity))
    {:ok, goal_snapshot} = Goal.snapshot(goal)
    assert goal_snapshot.goal.goal_id == goal_binding.expected_goal_id
    assert goal_snapshot.goal.tokens_used == 12
    assert map_size(goal_snapshot.receipts) > 0
    assert {:ok, ^goal_snapshot} = GoalFileStore.load(goal_store, thread)
    calls = GoalProxy.calls(proxy)
    assert Enum.any?(calls, &match?({:committed, %{type: :usage}}, &1))
    assert Enum.any?(calls, &match?({:committed, %{type: :turn_aborted}}, &1))
    assert Enum.any?(calls, &match?({:unbind, _}, &1))

    goal_evidence = %{
      owner: goal,
      store: goal_store,
      thread: thread,
      snapshot: goal_snapshot,
      proxy: proxy,
      calls: calls
    }

    {:ok, registry_manifest} =
      ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id)

    assert Enum.all?(registry_manifest["obligations"], &(&1["kind"] == "registry_resource"))

    # The real component DOWN above, not the lost cleanup reply, is the new evidence.
    confirm(host, registry_manifest, "registry", registry_manifest["obligations"])

    assert {:ok, registry_ack} =
             ResourceRegistry.reconcile_owner(
               binding.resource_registry,
               binding.owner_id,
               "registry"
             )

    assert {:ok, ^registry_ack} =
             ResourceRegistry.reconcile_owner(
               binding.resource_registry,
               binding.owner_id,
               "registry"
             )

    assert {:ok, %{status: :confirmed, initial_reason: :lost_cleanup_ack}} =
             ResourceRegistry.cleanup_status(binding.resource_registry, handle, binding.owner_id)

    {:ok, manifest} = Session.recovery_manifest(session)

    assert Enum.sort(Enum.map(manifest["obligations"], & &1["kind"])) == [
             "executor",
             "provider",
             "registry_owner"
           ]

    provider_obligation = Enum.find(manifest["obligations"], &(&1["kind"] == "provider"))
    {:ok, public_provider} = Evidence.public(provider_identity)
    assert provider_obligation["identity"] == public_provider
    executor = Enum.find(manifest["obligations"], &(&1["kind"] == "executor"))
    assert executor["identity"] == %{"run_id" => id, "incarnation" => 1}

    # An observed executor exit and confirmed Registry cannot substitute for the
    # accepted provider attempt's own observation.
    missing_provider = Enum.reject(manifest["obligations"], &(&1 == provider_obligation))
    partial = Shapes.bundle(manifest, Enum.map(missing_provider, &Shapes.observe/1))
    assert :ok = Host.put(host, {:evidence, "missing-provider"}, partial)
    request = Shapes.request(manifest, "session", "missing-provider")

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(host), request)

    assert {:error, %Error{class: :unknown_outcome}} = Session.reconcile_close(session, "session")

    assert {:ok, %{"retirement" => "pending", "pending" => [^provider_obligation]}} =
             Host.load_receipt(host, "session")

    assert_unchanged(host, id, authoritative, goal_evidence)

    complete = Shapes.bundle(manifest, Enum.map(manifest["obligations"], &Shapes.observe/1))
    assert complete["run_fences"] == []
    assert :ok = Host.put(host, {:evidence, "complete"}, complete)
    next = %{request | "expected_revision" => 1, "evidence_ref" => "complete"}

    assert {:ok, %{"retirement" => "confirmed", "historical_outcomes" => [historical]}} =
             Reconciliation.reconcile(Host.config(host), next)

    assert historical == %{
             "run_id" => id,
             "state" => "unknown_outcome",
             "outcome_digest" => Evidence.digest(authoritative.run.outcome)
           }

    assert {:ok, acknowledgement} = Session.reconcile_close(session, "session")
    assert {:ok, ^acknowledgement} = Session.reconcile_close(session, "session")
    assert {:ok, ^acknowledgement} = Session.close(session)

    assert %{phase: :closed, cleanup_revision: 1, initial_cleanup: first} =
             Session.status(session)

    assert first == initial_status.initial_cleanup
    assert {:error, %Error{class: :resource_conflict}} = Session.bind(session, %{run_id: "new"})
    assert {:error, %Error{}} = Session.validate(binding, %{})

    assert_unchanged(host, id, authoritative, goal_evidence)

    refute_receive :cleanup_called
    refute_receive {:provider_started, _, _}
    refute_receive {:goal_host_instruction, _, _}
    refute_receive {:goal_host_admission, _, _}
    refute_receive {:agent_runtime, ^id, _}
  end

  defp confirm(host, manifest, reference, obligations) do
    evidence = Shapes.bundle(manifest, Enum.map(obligations, &Shapes.observe/1))
    assert :ok = Host.put(host, {:evidence, reference}, evidence)

    assert {:ok, _} =
             Reconciliation.reconcile(
               Host.config(host),
               Shapes.request(manifest, reference, reference)
             )
  end

  defp assert_unchanged(host, id, record, %{
         owner: goal,
         store: store,
         thread: thread,
         snapshot: snapshot,
         proxy: proxy,
         calls: calls
       }) do
    # Full equality includes the run revision, journal, outcome, budgets, Goal
    # attribution receipts, outbox and conversation -- not just terminal status.
    assert {:ok, ^record} = Host.load(host, id)
    assert {:ok, ^snapshot} = Goal.snapshot(goal)
    assert {:ok, ^snapshot} = GoalFileStore.load(store, thread)
    assert GoalProxy.calls(proxy) == calls
  end

  defp drain_runtime_events(id) do
    receive do
      {:agent_runtime, ^id, _} -> drain_runtime_events(id)
    after
      0 -> :ok
    end
  end
end
