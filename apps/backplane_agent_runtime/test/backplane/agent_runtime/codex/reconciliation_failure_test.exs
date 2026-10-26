Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)
Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationFailureTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error, Kernel, Store, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes

  @moduletag :tmp_dir
  @moduletag capture_log: true

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

  for phase <- [:usage, :finish], fault <- [:refuse, :lose_ack] do
    test "real Conversation #{phase} #{fault} recovers a permanently closed Session", context do
      exercise(context, unquote(phase), unquote(fault))
    end
  end

  defp exercise(context, phase, fault) do
    {:ok, host} = Host.open(context.tmp_dir)
    on_exit(fn -> Host.cleanup(host) end)
    id = "live-#{phase}-#{fault}"
    authority = %{caller: "host", run_id: id, grants: []}

    session =
      start_supervised!(
        {Session,
         owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "live-failure"}
      )

    {:ok, binding} = Session.bind(session, authority, recovery_store_ref: "source-store")
    {:ok, component} = Agent.start_link(fn -> :owned_resource end)
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
      start_supervised!(
        {Conversation,
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
         work: 10,
         run_timeout: :infinity}
      )

    executor_monitor = Process.monitor(conversation)
    assert {:ok, _} = Conversation.prompt(conversation, "work once")
    assert_receive {:provider_started, request, provider}, 1_000
    provider_monitor = Process.monitor(provider)
    original_provider = Map.take(request, [:run_id, :incarnation, :step_id, :attempt_id])
    assert :ok = Host.fault_next(host, phase, fault)

    completed = %{type: :response_completed, message: %{role: :assistant, content: "answer"}}

    events =
      if phase == :usage,
        do: [%{type: :usage_updated, usage: %{input: 3, output: 2}}, completed],
        else: [completed]

    send(provider, {:events, events})
    assert_receive {:agent_runtime, ^id, %{type: :storage_failed}}, 1_000
    assert_receive :cleanup_called, 1_000
    assert_receive {:DOWN, ^component_monitor, :process, ^component, :normal}, 1_000
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, _}, 1_000
    assert eventually(fn -> Conversation.status(conversation).phase == :storage_failed end)

    assert %{phase: :closed, initial_cleanup: {:error, %Error{class: :unknown_outcome}}} =
             initial_status = Session.status(session)

    GenServer.stop(conversation)
    assert_receive {:DOWN, ^executor_monitor, :process, ^conversation, :normal}, 1_000
    {:ok, before_fence} = Host.load(host, id)
    assert Enum.any?(Map.values(before_fence.run.provider_attempts), &(&1 == original_provider))
    assert {:ok, fenced} = Store.fence(Host, host, id, before_fence.revision, 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             Store.fence(Host, host, id, before_fence.revision, 1, 3)

    unless Kernel.terminal?(fenced.run.state) do
      assert {:ok, _} = Store.store(Host, host, fenced.run, %{command: {:cancel, 10}})
      {:ok, %{run: cancelling}} = Host.load(host, id)

      assert {:ok, _} =
               Store.store(Host, host, cancelling, %{
                 command:
                   {:cleanup_settled, 11,
                    %{certainty: :confirmed, settled: Kernel.cleanup_requirements(cancelling)}}
               })
    end

    {:ok, authoritative} = Host.load(host, id)

    {:ok, registry_manifest} =
      ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id)

    assert Enum.all?(registry_manifest["obligations"], &(&1["kind"] == "registry_resource"))

    registry_bundle =
      Shapes.bundle(
        registry_manifest,
        Enum.map(registry_manifest["obligations"], &Shapes.observe/1)
      )

    assert :ok = Host.put(host, {:evidence, "registry"}, registry_bundle)

    assert {:ok, _} =
             Reconciliation.reconcile(
               Host.config(host),
               Shapes.request(registry_manifest, "registry", "registry")
             )

    assert {:ok, _} =
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

    {:ok, public_provider} =
      Backplane.AgentRuntime.Codex.Reconciliation.Evidence.public(original_provider)

    assert provider_obligation["identity"] == public_provider
    observations = Enum.map(manifest["obligations"], &Shapes.observe/1)

    chain = [
      %{
        "run_id" => id,
        "from_incarnation" => 1,
        "to_incarnation" => 2,
        "from_revision" => before_fence.revision,
        "to_revision" => before_fence.revision + 1,
        "source_ref" => "actual-public-store-fence"
      }
    ]

    complete = Shapes.bundle(manifest, observations) |> Map.put("run_fences", chain)

    missing = %{
      complete
      | "observations" =>
          Enum.reject(
            observations,
            &(&1["obligation_id"] == provider_obligation["obligation_id"])
          )
    }

    assert :ok = Host.put(host, {:evidence, "missing-provider"}, missing)
    request = Shapes.request(manifest, "session", "missing-provider")

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(host), request)

    assert {:error, %Error{class: :unknown_outcome}} = Session.reconcile_close(session, "session")
    assert :ok = Host.put(host, {:evidence, "complete"}, complete)
    next = %{request | "expected_revision" => 1, "evidence_ref" => "complete"}
    assert :ok = Host.fault_next(host, :receipt, fault)

    if fault == :refuse do
      assert {:error, %Error{class: :unknown_outcome}} =
               Reconciliation.reconcile(Host.config(host), next)

      assert {:ok, %{"revision" => 1}} = Host.load_receipt(host, "session")
    end

    assert {:ok, %{"revision" => 2, "retirement" => "confirmed"}} =
             Reconciliation.reconcile(Host.config(host), next)

    assert {:ok, acknowledgement} = Session.reconcile_close(session, "session")
    assert {:ok, ^acknowledgement} = Session.reconcile_close(session, "session")
    assert {:ok, ^acknowledgement} = Session.close(session)

    assert %{phase: :closed, cleanup_revision: 1, initial_cleanup: first} =
             Session.status(session)

    assert first == initial_status.initial_cleanup
    assert {:error, %Error{class: :resource_conflict}} = Session.bind(session, %{run_id: "new"})
    assert {:error, %Error{}} = Session.validate(binding, %{})
    assert {:ok, ^authoritative} = Host.load(host, id)
    refute_receive :cleanup_called
    refute_receive {:provider_started, _, _}
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, remaining - 1)
    end
  end
end
