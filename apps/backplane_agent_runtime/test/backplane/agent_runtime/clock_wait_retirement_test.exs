Code.require_file("../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.ClockWaitRetirementTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolEffects}

  alias Backplane.AgentRuntime.Codex.{
    Backend,
    MultiAgent,
    Reconciliation,
    ResourceRegistry,
    Session,
    Tools
  }

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  @moduletag capture_log: true
  @names ~w(clock::sleep clock::curr_time exec wait)
  @collaboration ~w(spawn_agent interrupt_agent list_agents)

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:clock_provider, request.run_id, request, self()})

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

  defmodule ProbeBackend do
    def execute(operation) do
      original = operation.backend_context.register_cancellation
      test = operation.backend_context.test

      register = fn admitted, registration ->
        result = original.(admitted, registration)

        if match?({:ok, _}, result),
          do: send(test, {:clock_registered, admitted, registration, self()})

        result
      end

      operation = put_in(operation.backend_context.register_cancellation, register)
      result = Backend.execute(operation)
      send(test, {:clock_returned, operation.invocation_id, result})
      result
    end
  end

  defmodule AckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      kind = elem(meta.command, 0)

      if kind in [:tool_invoked, :tool_completed] do
        send(context.test, {:clock_ack_pending, kind, self()})

        receive do
          :ack -> :ok
        end
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  defmodule MissingEvidenceStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def load(table, run_id, opts) do
      with {:ok, record} <- EphemeralStore.load(table, run_id, opts) do
        {:ok, put_in(record, [:run, :outcome, "cleanup", "evidence"], [])}
      end
    end
  end

  defmodule BadAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == context.kind do
        send(context.test, {:clock_bad_ack, context.kind, context.behavior, run.run_id})

        case context.behavior do
          :reject ->
            {:error, Error.new(:execution_failure, "fixture rejected clock commit")}

          :malformed ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)
            {:ok, %{revision: :invalid}}

          :lost ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)

            receive do
              :never_ack -> :unavailable
            end
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "normal clock completion waits for both Store ACKs and retains elapsed result" do
    host = Host.new()

    context =
      start_root(host, "normal", store: AckStore, context: %{table: host.store, test: self()})

    provider = prompt(context, "sleep briefly")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 10}), done()]})
    assert_receive {:clock_ack_pending, :tool_invoked, intent_writer}, 1_000
    refute_receive {:clock_registered, _, _, _}, 30
    send(intent_writer, :ack)
    assert_receive {:clock_registered, operation, _, _}, 1_000
    assert_receive {:clock_returned, invocation, {:ok, result}}, 1_000
    assert invocation == operation.invocation_id
    assert result.wall_time_seconds >= 0.01
    assert_receive {:clock_ack_pending, :tool_completed, result_writer}, 1_000
    refute_receive {:clock_provider, "normal", _, _}, 30

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.owner_transfer_ready(
               context.binding.resource_registry,
               context.binding.owner_id
             )

    send(result_writer, :ack)
    assert_receive {:clock_provider, "normal", request, next}, 1_000
    assert List.last(request.messages).result.wall_time_seconds == result.wall_time_seconds

    assert :ok =
             ResourceRegistry.owner_transfer_ready(
               context.binding.resource_registry,
               context.binding.owner_id
             )

    finish(context, next)
  end

  for kind <- [:tool_completed, :cleanup_settled], behavior <- [:reject, :malformed, :lost] do
    @tag ack_kind: kind, ack_behavior: behavior
    test "#{kind} #{behavior} ACK retains clock registration and blocks provider continuation",
         %{ack_kind: kind, ack_behavior: behavior} do
      host = Host.new()
      run = "ack-#{kind}-#{behavior}"

      context =
        start_root(host, run,
          store: BadAckStore,
          context: %{table: host.store, test: self(), kind: kind, behavior: behavior},
          commit_timeout: 100
        )

      provider = prompt(context, "wait for a clock commit")
      duration = if kind == :tool_completed, do: 10, else: 60_000
      send(provider, {:events, [call("clock::sleep", %{"duration_ms" => duration}), done()]})
      assert_receive {:clock_registered, operation, registration, _}, 1_000
      if kind == :cleanup_settled, do: assert(:ok == Conversation.cancel(context.conversation))
      assert_receive {:clock_bad_ack, ^kind, ^behavior, ^run}, 2_000
      eventually(fn -> Conversation.status(context.conversation).phase == :storage_failed end)
      state = :sys.get_state(context.conversation)
      assert state.cancellations[operation.invocation_id].registration == registration

      assert state.cancellations[operation.invocation_id].operation.clock_wait_admission ==
               operation.clock_wait_admission

      refute_receive {:clock_provider, ^run, _, _}, 30

      if kind == :tool_completed do
        assert_receive {:clock_returned, invocation, {:ok, %{wall_time_seconds: elapsed}}}, 1_000
        assert invocation == operation.invocation_id
        assert elapsed >= 0.01
      end
    end
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode
    test "#{mode} clock cancellation survives cold reconciliation and admits a real fresh prompt",
         %{mode: mode} do
      host = Host.new()
      context = start_root(host, "old-#{mode}")
      provider = prompt(context, "wait")
      {name, arguments} = clock_call(mode)
      send(provider, {:events, [call(name, arguments), done()]})
      assert_receive {:clock_registered, operation, _, executor}, 3_000
      executor_ref = Process.monitor(executor)
      assert :ok = Conversation.cancel(context.conversation)
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert_receive {:DOWN, ^executor_ref, :process, ^executor, _}, 2_000
      status = Conversation.status(context.conversation)
      assert status.run.state == :cancelled
      proofs = assert_proofs(status, operation, mode)
      assert {:ok, original} = EphemeralStore.load(host.store, context.run)
      assert original.run == status.run

      assert Enum.all?(
               proofs,
               &(&1 in retained_records(original.run.outcome["cleanup"]["evidence"]))
             )

      monitor = Process.monitor(context.conversation)
      stop_supervised!({:conversation, context.run})
      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      refute Process.alive?(provider)
      assert Session.status(context.session).phase == :closed

      assert {:ok, registry_manifest} =
               ResourceRegistry.recovery_manifest(
                 context.binding.resource_registry,
                 context.binding.owner_id
               )

      assert {:ok, registry_receipt} =
               reconcile_actual(host, registry_manifest, [], "registry-#{mode}")

      assert {:ok, _} =
               ResourceRegistry.reconcile_owner(
                 context.binding.resource_registry,
                 context.binding.owner_id,
                 registry_receipt["receipt_id"]
               )

      assert {:ok, manifest} = Session.recovery_manifest(context.session)
      assert {:ok, receipt} = reconcile_actual(host, manifest, proofs, "session-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               Session.reconcile_close(context.session, receipt["receipt_id"])

      assert_rejects_substitution(host, manifest, proofs, mode)
      :ok = Host.put(host, {:store, context.run}, {MissingEvidenceStore, host.store})

      assert {:error, %Error{class: :unknown_outcome}} =
               reconcile_actual(host, manifest, proofs, "absent-source-#{mode}")

      :ok = Host.put(host, {:store, context.run}, {EphemeralStore, host.store})
      assert_independent_wait_remains(host, manifest, proofs, mode)
      assert {:ok, ^original} = EphemeralStore.load(host.store, context.run)

      session_ref = Process.monitor(context.session)
      stop_supervised!({:session, context.run})
      assert_receive {:DOWN, ^session_ref, :process, _, _}, 1_000
      fresh = start_root(host, "fresh-#{mode}")
      refute fresh.binding.owner_id == context.binding.owner_id
      refute fresh.binding.resource_registry == context.binding.resource_registry
      next = prompt(fresh, "continue after the retired wait")
      send(next, {:events, [call("clock::curr_time", %{}), done()]})
      assert_receive {:clock_returned, _, {:ok, %{current_time: current_time}}}, 1_000
      assert is_binary(current_time)
      assert_receive {:clock_provider, run, request, final}, 1_000
      assert run == fresh.run
      assert List.last(request.messages).result.current_time == current_time
      finish(fresh, final)
      assert {:ok, ^original} = EphemeralStore.load(host.store, context.run)
    end
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode
    test "#{mode} managed child retains exact clock proof through manager reconciliation", %{
      mode: mode
    } do
      host = Host.new()
      test = self()
      names = @names ++ @collaboration
      root_auth = authority("parent", names)

      child_session =
        start_supervised!(
          {Session, owner_pid: test, recovery: Host.config(host), recovery_scope_id: "scope"},
          id: :child_session
        )

      contracts_table = :ets.new(:clock_contracts, [:public])

      manager =
        start_supervised!(
          {MultiAgent,
           root_agent_id: "root-agent",
           parent_run_id: "parent",
           parent_name: "/root",
           parent_authority: root_auth,
           min_wait_timeout_ms: 0,
           recovery: Host.config(host),
           recovery_scope_id: "scope",
           child_options: fn request, run, parent ->
             options =
               options(
                 child_session,
                 host,
                 run,
                 parent.child.incarnation,
                 names,
                 :ets.lookup_element(contracts_table, :contracts, 2),
                 test
               )

             {:ok, recovery_admission(host, request, parent, options)}
           end},
          id: :clock_manager
        )

      contracts = MultiAgent.contracts(:v2, manager)
      :ets.insert(contracts_table, {:contracts, contracts})
      root = start_root(host, "parent", names: names, contracts: contracts)
      provider = prompt(root, "spawn a clock worker")

      {parent, _} =
        tool(provider, "parent", "spawn_agent", %{"task_name" => "worker", "message" => "wait"})

      assert_receive {:clock_provider, child_run, _, child_provider}, 2_000
      {name, arguments} = clock_call(mode)
      send(child_provider, {:events, [call(name, arguments), done()]})
      assert_receive {:clock_registered, operation, _, executor}, 3_000
      ref = Process.monitor(executor)
      {parent, result} = tool(parent, "parent", "interrupt_agent", %{"target" => "/root/worker"})
      refute result[:is_error], inspect(result)
      assert_receive {:DOWN, ^ref, :process, ^executor, _}, 1_000
      assert {:ok, snapshot} = MultiAgent.snapshot(manager)
      [child] = snapshot.agents
      assert child.run_id == child_run
      assert child.cleanup == :confirmed
      child_pid = :sys.get_state(manager).agents[child.name].pid
      status = Conversation.status(child_pid)
      proofs = assert_proofs(status, operation, mode)
      assert {:ok, original} = EphemeralStore.load(host.store, child_run)
      assert original.run == status.run
      finish(root, parent)
      child_ref = Process.monitor(child_pid)
      assert :ok = MultiAgent.close_session(manager)
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 2_000
      refute Process.alive?(child_provider)
      assert Session.status(child_session).phase == :closed
      seal_child_inventory(host, child, status.run)
      assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, child.name)
      assert {:ok, receipt} = reconcile_actual(host, manifest, proofs, "child-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_child(manager, receipt["receipt_id"])

      assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, :manager)
      assert {:ok, receipt} = reconcile_actual(host, manifest, proofs, "manager-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_close(manager, receipt["receipt_id"])

      assert {:ok, ^original} = EphemeralStore.load(host.store, child_run)
    end
  end

  defp assert_proofs(status, operation, mode) do
    proofs = status.retirement_evidence
    clock = Enum.find(proofs, &(&1["record_type"] == "native_clock_wait_retirement"))
    assert is_map(clock)
    assert clock["identity"]["invocation_id"] == operation.invocation_id
    assert clock["executor_down"] == true
    assert clock["resources"] == "confirmed"
    assert clock["local_cleanup"] == "confirmed"
    assert clock["outcome"] == "unknown"
    assert clock["cancellation"]["record_type"] == "native_clock_cancellation"
    assert clock["cancellation"]["completion_gate"] == "closed"
    assert clock["cancellation"]["timer_retired"] == true
    assert clock["cancellation"]["waiter_down"] == true
    assert {:ok, ^clock} = ToolEffects.validate_retirement_record(clock, operation)

    if mode == :deno do
      outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))
      assert is_map(outer)
      assert clock["identity"]["enclosing_invocation_id"] == outer["identity"]["invocation_id"]
      assert clock["stop_generation"] == outer["stop_generation"]

      assert Enum.find(outer["nested"], &(&1["kind"] == "native_clock_wait_retirement")) == %{
               "kind" => "native_clock_wait_retirement",
               "identity" => clock["identity"],
               "evidence_digest" => clock["retirement_digest"]
             }
    end

    proofs
  end

  defp assert_rejects_substitution(host, manifest, proofs, mode) do
    clock = Enum.find(proofs, &(&1["record_type"] == "native_clock_wait_retirement"))

    changes = [
      put_in(clock, ["cancellation", "registration_id"], "another-registration"),
      put_in(clock, ["cancellation", "wait_generation"], "another-wait"),
      put_in(clock, ["identity", "invocation_id"], "another-invocation"),
      put_in(clock, ["provenance", "session_binding_identity", "owner_id"], "another-session"),
      Map.put(clock, "stop_generation", "another-stop"),
      put_in(clock, ["cancellation", "waiter_down"], false)
    ]

    for {changed, index} <- Enum.with_index(changes) do
      changed = Evidence.seal(changed, "retirement_digest")
      replaced = Enum.map(proofs, fn proof -> if proof == clock, do: changed, else: proof end)

      assert {:error, %Error{class: :unknown_outcome}} =
               reconcile_actual(host, manifest, replaced, "substitution-#{mode}-#{index}")
    end

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile_actual(host, manifest, [], "missing-#{mode}")

    if mode == :deno do
      outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))

      for {change, label} <- [
            {Map.put(outer, "nested", []), "missing-nested"},
            {Map.update!(outer, "nested", fn [entry | rest] ->
               [put_in(entry, ["identity", "enclosing_invocation_id"], "different-outer") | rest]
             end), "different-enclosing"}
          ] do
        changed = Evidence.seal(change, "retirement_digest")
        replaced = Enum.map(proofs, fn proof -> if proof == outer, do: changed, else: proof end)

        assert {:error, %Error{class: :unknown_outcome}} =
                 reconcile_actual(host, manifest, replaced, "nested-#{label}")
      end
    end
  end

  defp assert_independent_wait_remains(host, manifest, proofs, mode) do
    survivor = start_root(host, "survivor-#{mode}")
    provider = prompt(survivor, "independent wait")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 60_000}), done()]})
    assert_receive {:clock_registered, operation, _, executor}, 1_000
    assert {:ok, stored} = EphemeralStore.load(host.store, survivor.run)
    assert {:ok, obligations} = Reconciliation.run_obligations(stored.run, 1, "survivor-owner")

    combined =
      Host.manifest(
        manifest["subject"],
        manifest["run_refs"] ++
          [
            %{"store_ref" => survivor.run, "run_id" => survivor.run, "original_incarnation" => 1}
          ],
        manifest["obligations"] ++ obligations
      )

    assert {:error, %Error{}} = reconcile_actual(host, combined, proofs, "independent-#{mode}")
    assert Process.alive?(executor)

    assert Enum.any?(
             obligations,
             &(get_in(&1, ["identity", "invocation_id"]) == operation.invocation_id)
           )

    assert {:ok, ^stored} = EphemeralStore.load(host.store, survivor.run)
    survivor_run = survivor.run
    refute_receive {:clock_provider, ^survivor_run, _, _}, 30
    assert :ok = Conversation.cancel(survivor.conversation)
    eventually(fn -> Conversation.status(survivor.conversation).phase == :terminal end)
  end

  defp reconcile_actual(host, manifest, proofs, id) do
    observations =
      Enum.map(manifest["obligations"], fn obligation ->
        fact = Host.observe(obligation, "closed")

        if obligation["kind"] == "tool" do
          invocation = obligation["identity"]["invocation_id"]
          reference = id <> ":effect:" <> invocation
          proof = Enum.find(proofs, &(&1["identity"]["invocation_id"] == invocation))
          if proof, do: Host.put(host, {:evidence, reference}, proof)
          Map.put(fact, "effect_retirement_ref", reference)
        else
          fact
        end
      end)

    :ok = Host.put(host, {:evidence, id}, Host.bundle(manifest, observations))
    Reconciliation.reconcile(Host.config(host), Host.request(manifest, id, id))
  end

  defp start_root(host, run, overrides \\ []) do
    {names, overrides} = Keyword.pop(overrides, :names, @names)
    {contracts, overrides} = Keyword.pop(overrides, :contracts, [])

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "scope"},
        id: {:session, run}
      )

    options = options(session, host, run, 1, names, contracts, self()) |> Keyword.merge(overrides)
    conversation = start_supervised!({Conversation, options}, id: {:conversation, run})
    %{conversation: conversation, session: session, binding: options[:session_binding], run: run}
  end

  defp options(session, host, run, incarnation, names, extra_contracts, test) do
    bindings =
      Map.new(
        for contract <- extra_contracts,
            Map.has_key?(contract, :collaboration_binding),
            do: {contract.tool_name, contract.collaboration_binding.fingerprint}
      )

    auth = Map.put(authority(run, names), :tool_bindings, bindings)
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)

    local =
      Tools.contracts(%{
        resource_registry: binding.resource_registry,
        session_registry: binding.resource_registry
      })
      |> Enum.filter(&(&1.namespace == "clock"))
      |> Enum.map(fn contract ->
        %{
          contract
          | backend: ProbeBackend,
            backend_context: Map.put(contract.backend_context, :test, test)
        }
      end)

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: local ++ extra_contracts},
        auth,
        tools: names
      )

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: host.store,
      provider: Provider,
      provider_context: %{test: test},
      run_timeout: 20_000,
      effect_timeout: 10_000,
      cleanup_timeout: 2_000
    ]
  end

  defp recovery_admission(host, request, parent, options) do
    reference = "admission:" <> parent.child.attempt_id
    {:ok, request} = Evidence.public(request)

    {:ok, ceiling} =
      Evidence.public(
        Map.take(options[:authority], [:grants, :tool_revisions, :tool_bindings, :tool_revision])
      )

    config = %{"provider_ref" => "clock-provider", "profile" => "native-clock"}

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => parent.child.recovery_identity,
      "store_ref" => "source",
      "config_ref" => reference <> ":config",
      "authority_ceiling_ref" => reference <> ":ceiling",
      "tool_profile" => request["profile"],
      "admission_receipt_ref" => reference,
      "child_request" => request,
      "configuration" => config,
      "authority_ceiling" => ceiling,
      "artifact_refs" => [],
      "inventory_ref" => reference <> ":inventory"
    }

    :ok = Host.put(host, {:evidence, reference}, admission)
    :ok = Host.put(host, {:evidence, admission["config_ref"]}, config)
    :ok = Host.put(host, {:evidence, admission["authority_ceiling_ref"]}, ceiling)
    :ok = Host.put(host, {:store, "source"}, {EphemeralStore, host.store})

    Keyword.merge(options,
      recovery_admission_ref: reference,
      recovery_store_ref: "source",
      recovery_config_ref: admission["config_ref"],
      recovery_authority_ref: admission["authority_ceiling_ref"],
      recovery_tool_profile: String.to_existing_atom(request["profile"])
    )
  end

  defp seal_child_inventory(host, child, run) do
    {:ok, admission} = Host.load_evidence(host, "admission:" <> child.attempt_id)

    {:ok, obligations} =
      Reconciliation.run_obligations(run, run.incarnation, "actual-clock-runtime")

    :ok =
      Host.put(host, {:evidence, admission["inventory_ref"]}, %{
        "schema_version" => 1,
        "record_type" => "child_inventory",
        "child_identity" => admission["child_identity"],
        "complete" => true,
        "producer_ref" => "actual-managed-child-owner-ledger",
        "obligations" => obligations
      })
  end

  defp retained_records(%{"record_type" => type} = record)
       when type in ["native_clock_wait_retirement", "code_mode_retirement"],
       do: [record]

  defp retained_records(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&retained_records/1)

  defp retained_records(value) when is_list(value), do: Enum.flat_map(value, &retained_records/1)
  defp retained_records(_), do: []
  defp clock_call(:direct), do: {"clock::sleep", %{"duration_ms" => 60_000}}
  defp clock_call(:deno), do: {"exec", "return await tools.clock__sleep({duration_ms: 60000});"}
  defp authority(run, names), do: %{caller: "host", run_id: run, grants: names, tool_revision: 1}

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "clock-#{System.unique_integer([:positive])}",
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp prompt(context, text) do
    assert {:ok, _} = Conversation.prompt(context.conversation, text)
    assert_receive {:clock_provider, run, _, provider}, 1_000
    assert run == context.run
    provider
  end

  defp tool(provider, run, name, arguments) do
    send(provider, {:events, [call(name, arguments), done()]})
    assert_receive {:clock_provider, ^run, request, next}, 6_000
    {next, Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool)).result}
  end

  defp finish(context, provider) do
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :completed
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
