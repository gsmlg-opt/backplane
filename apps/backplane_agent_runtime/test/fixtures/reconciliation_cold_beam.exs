Code.require_file("reconciliation_file_host.exs", __DIR__)
Code.require_file("reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.ReconciliationColdBeamFixture do
  import ExUnit.Assertions
  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Kernel, Store, ToolRegistry}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  def run(mode, dir) do
    {:ok, host} = Host.open(dir)
    ctx = %{host: host, dir: dir, owner: self(), label: mode}
    apply(__MODULE__, String.to_existing_atom(mode), [ctx])
    Host.cleanup(host)
  end

  def producer(ctx) do
    :ok = Host.put(ctx.host, :producer_os_pid, System.pid())
    source = manager(ctx)
    assert {:ok, _} = call(source, "spawn_agent", %{"task_name" => "child", "message" => "work"})
    assert_receive {:prepared, child}, 1_000
    assert_receive {:binding, binding}, 1_000
    assert_receive {:provider, request, provider}, 1_000
    executor = :global.whereis_name({__MODULE__, request.run_id})
    assert is_pid(executor)
    executor_monitor = Process.monitor(executor)
    provider_monitor = Process.monitor(provider)
    {:ok, active} = Host.load(ctx.host, request.run_id)

    {:ok, original_obligations} =
      Reconciliation.run_obligations(
        active.run,
        child.incarnation,
        "cold-original-provider-ledger"
      )

    assert Enum.count(original_obligations, &(&1["kind"] == "provider")) == 1
    complete(source, request, provider)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}, 1_000

    assert {:ok, _} =
             call(source, "multi_agent_v1::close_agent", %{"target" => "/root/child"}, :v1)

    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, _}, 1_000
    refute Process.alive?(executor)
    assert_receive {:cleaned, attempt}, 1_000
    assert attempt == child.attempt_id

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(binding.session)

    {:ok, registry_manifest} =
      ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id)

    {:ok, component} = Host.get(ctx.host, {:component, child.attempt_id})

    assert Enum.any?(
             registry_manifest["obligations"],
             &(&1["identity"]["resource_id"] == component.resource_id)
           )

    assert {:ok, snapshot} = MultiAgent.snapshot(source)
    old = hd(snapshot.agents)
    assert String.ends_with?(old.run_id, ":" <> snapshot.manager_id <> ":1")

    :ok =
      Host.put(
        ctx.host,
        :old,
        Map.take(old, [:agent_id, :name, :attempt_id, :run_id, :incarnation])
      )

    :ok = Host.put(ctx.host, :old_binding, Map.take(binding, [:owner_id, :run_incarnation]))
    :ok = Host.put(ctx.host, :source_manager_id, snapshot.manager_id)
    {:ok, record} = Host.load(ctx.host, old.run_id)

    {:ok, obligations} =
      Reconciliation.run_obligations(record.run, old.incarnation, "cold-actual-run-ledger")

    obligations =
      Enum.uniq_by(
        original_obligations ++ obligations ++ registry_manifest["obligations"],
        &{&1["kind"], &1["identity"]}
      )

    :ok = Host.put(ctx.host, :source_obligations, obligations)
    :ok = Host.put(ctx.host, :source_terminal_record, record)

    inventory = %{
      "schema_version" => 1,
      "record_type" => "child_inventory",
      "child_identity" => child.recovery_identity,
      "complete" => true,
      "producer_ref" => "cold-owned-executor-and-session-ledger",
      "obligations" => obligations
    }

    :ok = Host.put(ctx.host, {:evidence, "inventory:" <> old.attempt_id}, inventory)
    {:ok, manifest} = MultiAgent.recovery_manifest(source, old.name)

    for kind <- ~w(provider executor registry_resource session) do
      assert Enum.any?(manifest["obligations"], &(&1["kind"] == kind))
    end

    :ok = Host.put(ctx.host, :source_manifest, manifest)
    receipt = reconcile(ctx, manifest, "child-retired")
    assert {:ok, _} = MultiAgent.reconcile_child(source, receipt["receipt_id"])
    {:ok, archive} = MultiAgent.export_child(source, old.name, receipt["receipt_id"])
    assert {:ok, public_messages} = Evidence.public(record.run.context.conversation.messages)
    assert archive["messages"] == public_messages

    assert archive["history_digest"] ==
             Evidence.digest(Map.take(archive, ~w(messages host_feedback)))

    assert Enum.any?(archive["messages"], &(&1["timestamp"] == "2026-10-27T00:00:00Z"))
    assert Enum.any?(archive["messages"], &(&1["role"] == "tool"))

    assert Enum.any?(archive["messages"], fn message ->
             match?(
               %{"class" => "not_found", "cause" => nil},
               get_in(message, ["result", "error"])
             )
           end)

    before_export = markers(ctx)
    archive = archive |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^archive} = MultiAgent.export_child(source, old.name, receipt["receipt_id"])
    assert markers(ctx) == before_export
    :ok = Host.put(ctx.host, :archive, archive)
    {:ok, manager_manifest} = MultiAgent.recovery_manifest(source, :manager)
    manager_receipt = reconcile(ctx, manager_manifest, "source-manager-retired")
    # Deliberately exit without projecting this committed manager receipt.
    :ok = Host.put(ctx.host, :unprojected_manager_receipt, manager_receipt)
    GenServer.stop(source)
    unknown_root(ctx)
    fault_runs(ctx)
    :ok = Host.put(ctx.host, :producer_markers, markers(ctx))
    :ok = Host.put(ctx.host, :producer_complete, true)

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: System.pid(),
        inventory_kinds: Enum.map(manifest["obligations"], & &1["kind"])
      })
    )
  end

  def consumer(ctx) do
    assert {:ok, true} = Host.get(ctx.host, :producer_complete)
    {:ok, producer_pid} = Host.get(ctx.host, :producer_os_pid)
    refute producer_pid == System.pid()
    :ok = Host.put(ctx.host, :consumer_os_pid, System.pid())
    {:ok, archive} = Host.get(ctx.host, :archive)
    archive = archive |> JSON.encode!() |> JSON.decode!()
    {:ok, old} = Host.get(ctx.host, :old)
    {:ok, source_record} = Host.get(ctx.host, :source_terminal_record)
    assert {:ok, ^source_record} = Host.load(ctx.host, old.run_id)
    {:ok, source_manifest} = Host.get(ctx.host, :source_manifest)
    {:ok, source_obligations} = Host.get(ctx.host, :source_obligations)
    assert Enum.all?(source_obligations, &(&1 in source_manifest["obligations"]))
    {:ok, old_binding} = Host.get(ctx.host, :old_binding)
    {:ok, prior_markers} = Host.get(ctx.host, :producer_markers)
    {:ok, manager_receipt} = Host.get(ctx.host, :unprojected_manager_receipt)

    assert {:ok, ^manager_receipt} =
             Reconciliation.load_confirmed(
               Host.config(ctx.host),
               manager_receipt["receipt_id"],
               manager_receipt["subject"]
             )

    destination = manager(ctx)
    assert {:ok, restored} = MultiAgent.restore_child(destination, archive)
    assert {:ok, ^restored} = MultiAgent.restore_child(destination, archive)
    assert :ok = MultiAgent.transfer_ready(destination)
    :ok = parent_only_turn(ctx, archive)
    assert markers(ctx) == prior_markers
    refute_receive {:prepared, _}, 0
    refute_receive {:provider, _, _}, 0
    refute_receive {:binding, _}, 0
    refute_receive {:cleaned, _}, 0
    {:ok, snapshot} = MultiAgent.snapshot(destination)
    assert snapshot.admissions == []
    assert [%{agent_id: id, archived: true, status: :closed, resident: false}] = snapshot.agents
    assert id == old.agent_id

    assert {:ok, _} =
             call(destination, "followup_task", %{"target" => old.name, "message" => "continue"})

    assert_receive {:prepared, fresh}, 1_000
    assert_receive {:binding, binding}, 1_000
    assert_receive {:provider, request, provider}, 1_000
    assert fresh.agent_id == old.agent_id
    assert fresh.incarnation > old.incarnation
    refute fresh.attempt_id == old.attempt_id
    refute binding.owner_id == old_binding.owner_id
    assert binding.run_incarnation == fresh.incarnation
    assert request.run_id == old.name <> ":" <> snapshot.manager_id <> ":1"
    refute request.run_id == old.run_id
    assert Enum.any?(request.messages, &(&1 == metadata_message()))

    assert {:ok, source_messages} =
             Evidence.public(source_record.run.context.conversation.messages)

    assert archive["messages"] == source_messages

    assert Enum.take(request.messages, length(source_messages)) ==
             source_record.run.context.conversation.messages

    assert Enum.any?(request.messages, fn message ->
             match?(%Error{class: :not_found, cause: nil}, get_in(message, [:result, :error]))
           end)

    assert Enum.any?(request.messages, &(&1[:content] == "continue"))
    complete(destination, request, provider)
    assert :ok = MultiAgent.close_session(destination)
    GenServer.stop(destination)
    unknown_consumer(ctx)
    recover_fault_runs(ctx)
    assert {:ok, ^source_record} = Host.load(ctx.host, old.run_id)

    assert markers(ctx) ==
             Map.merge(prior_markers, %{
               "consumer:prepared" => 1,
               "consumer:provider" => 1,
               "consumer:cleaned" => 1
             })

    :ok = Host.put(ctx.host, :consumer_complete, true)
    :ok = Host.put(ctx.host, :consumer_markers, markers(ctx))

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: producer_pid,
        consumer_os_pid: System.pid(),
        source_run_id: old.run_id,
        destination_run_id: request.run_id,
        source_attempt_id: old.attempt_id,
        destination_attempt_id: fresh.attempt_id,
        markers_before_import: prior_markers,
        markers_after_followup: markers(ctx)
      })
    )
  end

  defp manager(ctx) do
    {:ok, pid} =
      MultiAgent.start_link(
        parent_run_id: "root-" <> ctx.label,
        parent_name: "/root",
        parent_authority: %{
          caller: "host",
          run_id: "root-" <> ctx.label,
          grants: ["read"],
          tool_revision: 1
        },
        root_agent_id: "stable-root",
        recovery_scope_id: "cold-scope",
        recovery: Host.config(ctx.host),
        child_options: &child_options(ctx, &1, &2, &3),
        min_wait_timeout_ms: 0
      )

    Process.put({:root_run, pid}, "root-" <> ctx.label)
    pid
  end

  defp child_options(ctx, request, run_id, parent) do
    marker(ctx, "prepared")
    send(ctx.owner, {:prepared, parent.child})
    id = parent.child.attempt_id
    configuration = %{"provider_ref" => "cold-provider", "profile" => "cold"}

    ceiling = %{
      "grants" => ["read"],
      "tool_revision" => 1,
      "tool_revisions" => %{},
      "tool_bindings" => %{}
    }

    {:ok, public_request} = Evidence.public(request)

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => parent.child.recovery_identity,
      "store_ref" => "source-store",
      "config_ref" => "config:" <> id,
      "authority_ceiling_ref" => "ceiling:" <> id,
      "tool_profile" => Atom.to_string(request.profile),
      "admission_receipt_ref" => "admission:" <> id,
      "child_request" => public_request,
      "configuration" => configuration,
      "authority_ceiling" => ceiling,
      "artifact_refs" => [],
      "inventory_ref" => "inventory:" <> id
    }

    for {ref, value} <- [
          {"admission:" <> id, admission},
          {"config:" <> id, configuration},
          {"ceiling:" <> id, ceiling}
        ],
        do: :ok = Host.put(ctx.host, {:evidence, ref}, value)

    authority = %{caller: "host", run_id: run_id, grants: ["read"], tool_revision: 1}

    {:ok, session} =
      Session.start_link(
        owner_pid: ctx.owner,
        cleanup_timeout: 1_000,
        recovery: Host.config(ctx.host),
        recovery_scope_id: "cold-scope"
      )

    {:ok, binding} = Session.bind(session, authority, incarnation: parent.child.incarnation)

    component =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, handle} =
      ResourceRegistry.register(
        binding.resource_registry,
        binding.owner_id,
        :component,
        component,
        cleanup: fn ->
          monitor = Process.monitor(component)
          send(component, :stop)

          receive do
            {:DOWN, ^monitor, :process, ^component, :normal} ->
              marker(ctx, "cleaned")
              send(ctx.owner, {:cleaned, id})
              :ok
          after
            1_000 ->
              {:error, Error.new(:unknown_outcome, "fixture component stop was not observed")}
          end
        end
      )

    :ok = Host.put(ctx.host, {:component, id}, handle)
    send(ctx.owner, {:binding, binding})

    {:ok,
     [
       name: {:global, {__MODULE__, run_id}},
       run_id: run_id,
       store: Host,
       context: ctx.host,
       provider: __MODULE__.Provider,
       provider_context: ctx,
       registry: registry(Map.put(ctx, :binding, binding)),
       hooks: __MODULE__,
       authority: authority,
       schema_admission: :strict,
       work: 10,
       run_timeout: :infinity,
       session_binding: binding,
       recovery_admission_ref: "admission:" <> id,
       recovery_store_ref: "source-store",
       recovery_config_ref: "config:" <> id,
       recovery_authority_ref: "ceiling:" <> id,
       recovery_tool_profile: request.profile
     ]}
  end

  defp call(manager, tool, args, profile \\ :v2) do
    MultiAgent.call(%{
      backend_context: %{runtime: manager, profile: profile},
      run_id: Process.get({:root_run, manager}),
      tool_name: tool,
      arguments: args
    })
  end

  defp complete(manager, request, provider) do
    if Enum.any?(request.messages, &(&1[:role] == :tool)) do
      send(provider, {:events, [%{type: :response_completed, message: metadata_message()}]})
    else
      send(
        provider,
        {:events,
         [
           %{
             type: :response_completed,
             message: %{
               role: :assistant,
               content: [
                 %{type: :text, text: "工具调用\r\n"},
                 %{type: :tool_call, id: "cold-read", name: "read", arguments: %{}}
               ],
               phase: :commentary,
               provider: "fixture",
               usage: %{input_tokens: 1}
             }
           }
         ]}
      )

      assert_receive {:provider, next_request, next_provider}, 1_000
      assert Enum.any?(next_request.messages, &(&1[:role] == :tool))
      send(next_provider, {:events, [%{type: :response_completed, message: metadata_message()}]})
    end

    assert eventually(fn ->
             {:ok, snapshot} = MultiAgent.snapshot(manager)

             Enum.any?(
               snapshot.agents,
               &(&1.run_id == request.run_id and &1.status == :completed)
             )
           end)
  end

  defp metadata_message do
    %{
      role: :assistant,
      content: [%{type: :text, text: "retained cold answer\r\n你好"}],
      timestamp: "2026-10-27T00:00:00Z",
      usage: %{input_tokens: 3, output_tokens: 2},
      provider: "fixture",
      model: "fixture-model",
      api: "responses",
      stop_reason: :stop,
      phase: :final,
      extension: %{"future" => [%{"unicode" => "保留\r\n", "nullable" => nil}]}
    }
  end

  defp registry(ctx) do
    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "read",
        tool_revision: 1,
        description: "cold read",
        backend: __MODULE__.Backend,
        backend_context: ctx,
        schema: %{"type" => "object", "properties" => %{}},
        safety: %{read_only: true, retry_safe: true, parallel_safe: false}
      })

    registry
  end

  def tool_effect_timeout(_invocation, ctx) do
    marker(ctx, "selector")
    :default
  end

  defmodule Backend do
    def execute(operation) do
      Backplane.AgentRuntime.ReconciliationColdBeamFixture.marker(
        operation.backend_context,
        "tool"
      )

      binding = operation.backend_context.binding

      {:error, error} =
        ResourceRegistry.fetch_session(
          binding.resource_registry,
          999_999,
          binding.owner_id,
          binding.run_incarnation
        )

      {:ok, %{is_error: true, error: error, content: [%{type: :text, text: "读取\r\n"}]}}
    end
  end

  defp parent_only_turn(ctx, archive) do
    ctx = %{ctx | label: ctx.label <> "-parent-only"}
    manager = manager(ctx)
    assert {:ok, _} = MultiAgent.restore_child(manager, archive)
    run_id = "root-" <> ctx.label
    authority = %{caller: "host", run_id: run_id, grants: ["list_agents"], tool_revision: 1}
    {:ok, session} = Session.start_link(owner_pid: self(), cleanup_timeout: 1_000)
    {:ok, binding} = Session.bind(session, authority)

    context = %{
      session_binding: binding,
      collaboration_runtime: manager,
      caller: %{run_id: run_id}
    }

    {:ok, profile} =
      Codex.profile(:configured, context, authority,
        families: [:collaboration_v2],
        tools: ["list_agents"]
      )

    {:ok, conversation} =
      Conversation.start_link(
        run_id: run_id,
        store: Host,
        context: ctx.host,
        provider: __MODULE__.ParentProvider,
        provider_context: %{owner: self()},
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        session_binding: binding,
        schema_admission: :strict,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "parent only")
    assert_receive {:parent_only_provider, %{run_id: ^run_id}}, 1_000
    assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert Conversation.status(conversation).run.state == :completed
    assert {:ok, %{run: %{state: :completed}}} = Host.load(ctx.host, run_id)
    assert Session.status(session).phase == :idle
    GenServer.stop(conversation)
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    GenServer.stop(session)
    GenServer.stop(manager)
    :ok
  end

  defmodule ParentProvider do
    def stream(request, %{owner: owner}) do
      send(owner, {:parent_only_provider, request})
      [%{type: :response_completed, message: %{role: :assistant, content: "root-only done"}}]
    end
  end

  defp eventually(fun, count \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, count) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, count - 1)
    end
  end

  def marker(ctx, name),
    do: File.write!(Path.join(ctx.dir, "markers"), ctx.label <> ":" <> name <> "\n", [:append])

  defp markers(ctx),
    do:
      File.read!(Path.join(ctx.dir, "markers"))
      |> String.split("\n", trim: true)
      |> Enum.frequencies()

  defp observe(obligation) do
    obligation
    |> Shapes.observe()
    |> Map.put("source_ref", "cold-host-observed-lifecycle-ledger")
    |> Map.put("observed_at_unix_ms", System.system_time(:millisecond))
  end

  defp reconcile(ctx, manifest, id, observations \\ nil) do
    ref = "bundle:" <> id
    observations = observations || Enum.map(manifest["obligations"], &observe/1)
    :ok = Host.put(ctx.host, {:evidence, ref}, Shapes.bundle(manifest, observations))
    request = Shapes.request(manifest, id, ref)
    assert {:ok, receipt} = Reconciliation.reconcile(Host.config(ctx.host), request)
    receipt
  end

  defp unknown_root(ctx) do
    run = %{
      run_id: "unknown-root",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      context: %{
        conversation: %{
          goal_outbox: [%{receipt_id: "goal-retained", payload: "unchanged"}],
          goal_usage: %{input_tokens: 7}
        }
      }
    }

    commit(ctx, run, {:admit, 1, %{state: :running}})

    identity = %{
      run_id: run.run_id,
      incarnation: 1,
      step_id: "step",
      attempt_id: "provider-original"
    }

    run = load_run(ctx, run.run_id)

    {provider, provider_monitor} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        end
      end)

    marker(ctx, "root-provider")
    commit(ctx, run, {:provider_started, 2, identity})
    commit(ctx, load_run(ctx, run.run_id), {:cancel, 3})

    commit(
      ctx,
      load_run(ctx, run.run_id),
      {:cleanup_settled, 4,
       %{certainty: :uncertain, evidence: %{reason: "provider acknowledgement unavailable"}}}
    )

    {:ok, original} = Host.load(ctx.host, run.run_id)
    assert original.run.state == :unknown_outcome

    :ok =
      Host.put(
        ctx.host,
        :unknown_original_bytes,
        :erlang.term_to_binary(original, [:deterministic])
      )

    {:ok, obligations} =
      Reconciliation.run_obligations(original.run, 1, "exact-original-provider-ledger")

    assert Enum.any?(
             obligations,
             &(&1["kind"] == "provider" and &1["identity"]["attempt_id"] == "provider-original")
           )

    subject = %{
      "kind" => "session",
      "scope_id" => "cold-scope",
      "owner_id" => "unknown-root-owner",
      "incarnation" => 1
    }

    manifest =
      Shapes.manifest(
        subject,
        [%{"store_ref" => "source-store", "run_id" => run.run_id, "original_incarnation" => 1}],
        obligations
      )

    :ok = Host.put(ctx.host, :unknown_manifest, manifest)
    # Provider is a host-owned simulated attempt with an explicit observed stop;
    # BEAM death alone is used only for the local executor in the consumer.
    send(provider, :stop)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}, 1_000
    providers = Enum.filter(obligations, &(&1["kind"] == "provider"))
    :ok = Host.put(ctx.host, :unknown_provider_observations, Enum.map(providers, &observe/1))
  end

  defp unknown_consumer(ctx) do
    {:ok, bytes} = Host.get(ctx.host, :unknown_original_bytes)
    {:ok, original} = Host.load(ctx.host, "unknown-root")
    assert :erlang.term_to_binary(original, [:deterministic]) == bytes
    {:ok, manifest} = Host.get(ctx.host, :unknown_manifest)
    {:ok, providers} = Host.get(ctx.host, :unknown_provider_observations)
    executors = Enum.filter(manifest["obligations"], &(&1["kind"] == "executor"))
    :ok = Host.fault_next(ctx.host, :receipt, :lose_ack)

    receipt =
      reconcile(ctx, manifest, "unknown-lifetime", providers ++ Enum.map(executors, &observe/1))

    assert receipt["historical_outcomes"] |> hd() |> Map.fetch!("state") == "unknown_outcome"
    assert {:ok, after_receipt} = Host.load(ctx.host, "unknown-root")
    assert :erlang.term_to_binary(after_receipt, [:deterministic]) == bytes
    # Explicit inventories cannot be silently reduced to provider-only closure.
    for kind <- ~w(tool child dependency host_component acknowledgement) do
      extra =
        Evidence.obligation(
          kind,
          %{"run_id" => "unknown-root", "incarnation" => 1, "component_id" => kind},
          "explicit-host-ledger"
        )

      expanded =
        Shapes.manifest(
          manifest["subject"],
          manifest["run_refs"],
          manifest["obligations"] ++ [extra]
        )

      ref = "omitted:" <> kind

      :ok =
        Host.put(
          ctx.host,
          {:evidence, ref},
          Shapes.bundle(expanded, providers ++ Enum.map(executors, &observe/1))
        )

      assert {:error, %Error{class: :unknown_outcome}} =
               Reconciliation.reconcile(Host.config(ctx.host), Shapes.request(expanded, ref, ref))
    end

    assert {:ok, final} = Host.load(ctx.host, "unknown-root")
    assert :erlang.term_to_binary(final, [:deterministic]) == bytes
  end

  defp fault_runs(ctx) do
    for phase <- [:usage, :finish], fault <- [:refuse, :lose_ack] do
      id = "fault-#{phase}-#{fault}"
      run = %{run_id: id, incarnation: 1, expected_revision: 0, state: :queued}
      commit(ctx, run, {:admit, 1, %{state: :running}})
      run = load_run(ctx, id)

      command =
        if phase == :usage,
          do:
            {:conversation_updated, 2,
             %{run_id: id, incarnation: 1, conversation: %{usage: [%{input_tokens: 3}]}}},
          else: {:finish, 2, %{run_id: id, incarnation: 1, status: :completed, outcome: "done"}}

      :ok = Host.fault_next(ctx.host, phase, fault)

      assert {:error, %Error{class: :unknown_outcome}} =
               Store.store(Host, ctx.host, run, %{command: command})

      {:ok, committed} = Host.load(ctx.host, id)
      assert committed.revision == if(fault == :refuse, do: 1, else: 2)
      :ok = Host.put(ctx.host, {:fault_before, id}, committed)
    end
  end

  defp recover_fault_runs(ctx) do
    for phase <- [:usage, :finish], fault <- [:refuse, :lose_ack] do
      id = "fault-#{phase}-#{fault}"
      {:ok, before} = Host.get(ctx.host, {:fault_before, id})
      assert {:ok, ^before} = Host.load(ctx.host, id)
      assert {:ok, fenced} = Store.fence(Host, ctx.host, id, before.revision, 1, 2)

      assert {:error, %Error{class: :resource_conflict}} =
               Store.fence(Host, ctx.host, id, before.revision, 1, 3)

      assert {:error, %Error{class: :resource_conflict}} =
               Store.fence(Host, ctx.host, id, fenced.revision, 1, 3)

      assert {:ok, after_stale_probe} = Host.load(ctx.host, id)
      assert after_stale_probe.run == fenced.run
      assert after_stale_probe.revision == fenced.revision

      unless Kernel.terminal?(before.run.state) do
        assert {:error, %Error{class: :resource_conflict}} =
                 Store.store(Host, ctx.host, before.run, %{command: {:cancel, 5}})
      end

      unless Kernel.terminal?(fenced.run.state) do
        commit(ctx, fenced.run, {:cancel, 5})
        current = load_run(ctx, id)

        commit(
          ctx,
          current,
          {:cleanup_settled, 6,
           %{certainty: :confirmed, settled: Kernel.cleanup_requirements(current)}}
        )
      end

      current = load_run(ctx, id)
      {:ok, obligations} = Reconciliation.run_obligations(current, 1, "cold-fault-ledger")

      subject = %{
        "kind" => "session",
        "scope_id" => "cold-scope",
        "owner_id" => id,
        "incarnation" => 1
      }

      manifest =
        Shapes.manifest(
          subject,
          [%{"store_ref" => "source-store", "run_id" => id, "original_incarnation" => 1}],
          obligations
        )

      chain = [
        %{
          "run_id" => id,
          "from_incarnation" => 1,
          "to_incarnation" => 2,
          "from_revision" => before.revision,
          "to_revision" => before.revision + 1,
          "source_ref" => "persisted-host-fence-journal"
        }
      ]

      bundle =
        Shapes.bundle(manifest, Enum.map(obligations, &observe/1)) |> Map.put("run_fences", chain)

      ref = "recovered:" <> id
      :ok = Host.put(ctx.host, {:evidence, ref}, bundle)

      assert {:ok, %{"retirement" => "confirmed"}} =
               Reconciliation.reconcile(Host.config(ctx.host), Shapes.request(manifest, ref, ref))
    end
  end

  defp commit(ctx, run, command),
    do: assert({:ok, _} = Store.store(Host, ctx.host, run, %{command: command}))

  defp load_run(ctx, id) do
    {:ok, %{run: run}} = Host.load(ctx.host, id)
    run
  end

  defmodule Provider do
    def stream(request, ctx) do
      Backplane.AgentRuntime.ReconciliationColdBeamFixture.marker(ctx, "provider")
      send(ctx.owner, {:provider, request, self()})

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
end

[mode, dir] = System.argv()
Backplane.AgentRuntime.ReconciliationColdBeamFixture.run(mode, dir)
