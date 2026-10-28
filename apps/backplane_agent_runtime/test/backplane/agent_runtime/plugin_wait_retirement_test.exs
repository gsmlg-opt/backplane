Code.require_file("../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.PluginWaitRetirementTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolEffects}

  alias Backplane.AgentRuntime.Codex.{
    CodeMode,
    DynamicRuntime,
    ResourceRegistry,
    Session,
    Reconciliation
  }

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.McpProtocol.Client
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  @moduletag capture_log: true
  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:plugin_provider, request, self()})

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

  defmodule PluginHost do
    def request_install(arguments, operation) do
      %{test: test, requests: requests} = operation.backend_context
      reference = "host-request:" <> operation.invocation_id
      true = :ets.insert_new(requests, {reference, arguments, operation.plugin_request_id})
      send(test, {:host_request_ack, reference, operation})

      apply(DynamicRuntime, :plugin_install_wait, [
        operation,
        reference,
        fn ->
          send(test, {:plugin_observer, self()})

          receive do
            :installed -> {:ok, %{installed: true}}
          end
        end
      ])
    end
  end

  defmodule InstalledMcpTool do
    def execute(operation) do
      with {:ok, handle} <-
             Client.start_read_resource(
               operation.backend_context.client,
               "mem://after-install"
             ),
           {:ok, response} <- Client.await_resource_request(handle, 1_000) do
        send(operation.backend_context.test, {:installed_mcp, operation})
        {:ok, response.result}
      end
    end
  end

  defmodule ObserveTool do
    def execute(operation) do
      send(operation.backend_context.test, {:settled_native, operation})
      {:ok, %{observed: true}}
    end
  end

  defmodule LegacyPluginHost do
    def request_install(_arguments, operation) do
      send(operation.backend_context.test, {:legacy_plugin, operation, self()})

      receive do
        :installed -> {:ok, %{installed: true}}
      end
    end
  end

  defmodule PostHookAdapter do
    def execute(operation) do
      operation =
        if operation.backend_context[:family] == :code_mode do
          callback = operation.backend_context.register_code_mode
          test = operation.backend_context.adapter_test

          wrapped = fn op, registry, handle, worker ->
            wrong_worker = callback.(op, registry, handle, self())
            wrong_owner = callback.(op, registry, %{handle | owner_id: "foreign"}, worker)

            send(
              test,
              {:native_registration_probe, callback, op, registry, handle, worker, wrong_worker,
               wrong_owner}
            )

            callback.(op, registry, handle, worker)
          end

          put_in(operation.backend_context.register_code_mode, wrapped)
        else
          operation
        end

      case Backplane.AgentRuntime.Codex.Backend.execute(operation) do
        {:ok, result} ->
          if operation.backend_context[:post_block],
            do:
              ToolEffects.present(operation, result, %{type: :block, text: "post hook blocked"}),
            else: {:ok, result}

        other ->
          other
      end
    end
  end

  defmodule UnregisteredAdapter do
    def execute(operation) do
      operation = update_in(operation.backend_context, &Map.delete(&1, :register_code_mode))
      Backplane.AgentRuntime.Codex.Backend.execute(operation)
    end
  end

  for mode <- [:direct, :deno, :deno_wait], adapted <- [false, true] do
    @tag mode: mode, adapted: adapted
    test "#{mode} adapted=#{adapted} acknowledged plugin wait has exact independent retirement",
         %{mode: mode, adapted: adapted} = ctx do
      requests = :ets.new(:plugin_requests, [:public, :set])
      runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})
      {conversation, store, _session} = start_run(runtime, requests, "original-#{mode}", adapted)
      assert {:ok, _} = Conversation.prompt(conversation, "request installation")
      assert_receive {:plugin_provider, request, provider}, 1_000

      args = arguments()

      {name, payload} =
        if mode == :direct,
          do: {"request_plugin_install", args},
          else:
            {"exec",
             "await tools.fixture__observe({}); return await tools.request_plugin_install(#{JSON.encode!(args)});"}

      payload = if mode == :deno_wait, do: "yield_control(); " <> payload, else: payload
      send(provider, {:events, [call(name, payload), done()]})

      if mode == :deno_wait do
        assert_receive {:plugin_provider, yielded, continuation}, 2_000
        result = List.last(yielded.messages).result
        assert result.status == :yielded
        send(continuation, {:events, [call("wait", %{"cell_id" => result.cell_id}), done()]})
      end

      assert_receive {:host_request_ack, reference, operation}, 2_000
      assert_receive {:plugin_observer, observer}, 2_000

      if adapted and mode != :direct do
        assert_receive {:native_registration_probe, callback, native_op, registry, handle, worker,
                        {:error, %Error{class: :resource_conflict}},
                        {:error, %Error{class: :resource_conflict}}},
                       1_000

        assert {:error, %Error{class: :resource_conflict}} =
                 callback.(native_op, registry, handle, worker)
      end

      assert observer != runtime
      state = :sys.get_state(conversation)
      task = if mode == :direct, do: state.effect.task, else: state.nested.task
      assert observer == task.pid

      executor =
        if mode != :direct do
          assert_receive {:settled_native, settled}
          assert settled.enclosing_invocation_id == operation.enclosing_invocation_id

          {:ok, supervisor} =
            ResourceRegistry.worker_supervisor(
              operation.backend_context.resource_owner.resource_registry
            )

          [{_, worker, _, _}] = DynamicSupervisor.which_children(supervisor)
          {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
          {worker, os_identity, settled}
        end

      observer_ref = Process.monitor(observer)
      before = :ets.tab2list(requests)
      assert :ok = Conversation.cancel(conversation)
      eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert_receive {:DOWN, ^observer_ref, :process, ^observer, _}, 2_000
      status = Conversation.status(conversation)
      assert status.run.state == :cancelled
      proofs = Map.fetch!(status, :retirement_evidence)
      plugin = Enum.find(proofs, &(&1["record_type"] == "native_plugin_wait_retirement"))
      assert plugin["identity"]["invocation_id"] == operation.invocation_id
      assert plugin["host_request_ref"] == reference
      assert plugin["plugin_request_id"] == operation.plugin_request_id
      assert plugin["waiter_down"] == true
      assert plugin["completion_gate"] == "closed"
      assert plugin["local_cleanup"] == "confirmed"
      assert plugin["outcome"] == "unknown"

      assert {:ok, retained} =
               apply(DynamicRuntime, :plugin_install_retirement, [
                 runtime,
                 Backplane.AgentRuntime.ToolEffects.cancellation_identity(operation)
               ])

      assert retained == plugin
      assert {:ok, ^plugin} = ToolEffects.validate_retirement_record(plugin, operation)
      assert map_size(status.run.tool_results) == %{direct: 0, deno: 1, deno_wait: 2}[mode]

      for changed <- [
            Map.delete(ToolEffects.cancellation_identity(operation), :turn_id),
            Map.put(ToolEffects.cancellation_identity(operation), :tool_call_id, "another")
          ] do
        assert {:error, %Error{class: :unknown_outcome}} =
                 DynamicRuntime.plugin_install_retirement(runtime, changed)
      end

      for changed <- [
            Map.put(plugin, "completion_gate", "open"),
            Map.put(plugin, "waiter_down", false),
            Map.put(plugin, "provenance", %{}),
            Map.put(plugin, "unexpected", true)
          ] do
        changed = Evidence.seal(changed, "retirement_digest")

        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.validate_retirement_record(changed, operation)
      end

      if mode != :direct do
        outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))
        assert outer["identity"]["invocation_id"] != operation.invocation_id
        assert outer["executor_down"] == true
        assert outer["resources"] == "confirmed"

        assert length(outer["nested"]) == 2

        assert Enum.find(outer["nested"], &(&1["kind"] == "native_plugin_wait_retirement")) ==
                 %{
                   "kind" => "native_plugin_wait_retirement",
                   "identity" => plugin["identity"],
                   "evidence_digest" => plugin["retirement_digest"]
                 }

        {worker, os_identity, settled} = executor
        acknowledged = Enum.find(outer["nested"], &(&1["kind"] == "acknowledged_settlement"))
        assert acknowledged["identity"]["invocation_id"] == settled.invocation_id

        assert acknowledged["evidence_digest"] ==
                 Evidence.digest(%{
                   identity:
                     Map.put(
                       ToolEffects.cancellation_identity(settled),
                       :session_binding_identity,
                       operation.session_binding_identity
                     ),
                   result: status.run.tool_results[settled.invocation_id]
                 })

        refute Process.alive?(worker)
        assert :ok = CodeMode.Worker.cleanup_identity(os_identity)
      end

      assert {:ok, original} = EphemeralStore.load(store, request.run_id)
      assert before == :ets.tab2list(requests)
      # Explicit host installation is separate from the now-retired observation.
      client = start_client(ctx.tmp_dir, mode)
      true = :ets.insert(requests, {:installed, %{reference: reference, client: client}})
      send(observer, :installed)
      assert {:ok, ^original} = EphemeralStore.load(store, request.run_id)
      refute_receive {:plugin_provider, _, _}, 30

      {next, _, _} = start_run(runtime, requests, "fresh-#{mode}", adapted)
      assert {:ok, _} = Conversation.prompt(next, "continue with installed inventory")
      assert_receive {:plugin_provider, fresh, fresh_provider}, 1_000
      assert fresh.run_id != request.run_id
      assert Enum.any?(fresh.tools, &(&1.name == "fixture::installed_mcp"))

      {tool, input} =
        if mode == :direct,
          do: {"fixture::installed_mcp", %{}},
          else: {"exec", "return await tools.fixture__installed_mcp({});"}

      send(fresh_provider, {:events, [call(tool, input), done()]})
      assert_receive {:installed_mcp, installed}, 2_000
      assert installed.run_id == fresh.run_id
      assert installed.invocation_id != operation.invocation_id
      assert_receive {:plugin_provider, %{messages: messages}, fresh_provider}, 2_000
      assert List.last(messages).result.is_error == false
      send(fresh_provider, {:events, [done()]})
      eventually(fn -> Conversation.status(next).phase == :terminal end)
      assert :ets.lookup(requests, reference) == before
      refute_receive {:host_request_ack, _, _}, 30
      assert {:ok, ^original} = EphemeralStore.load(store, request.run_id)

      wires =
        Path.join(ctx.tmp_dir, "installed-wire.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      assert Enum.count(wires, &(&1["method"] == "initialize")) == 1
      assert Enum.count(wires, &(&1["method"] == "resources/read")) == 1
      assert Enum.any?(wires, &(get_in(&1, ["params", "uri"]) == "mem://after-install"))
      assert_reconciled(store, original, proofs, operation)
      client_pid = GenServer.whereis(client)
      monitor = Process.monitor(client_pid)
      stop_supervised!({:installed_client, mode})
      assert_receive {:DOWN, ^monitor, :process, ^client_pid, _}
    end
  end

  test "family metadata without native registration cannot confirm outer retirement" do
    requests = :ets.new(:unregistered_requests, [:public, :set])
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})
    {conversation, _, _} = start_run(runtime, requests, "unregistered", :unregistered)
    assert {:ok, _} = Conversation.prompt(conversation, "request")
    assert_receive {:plugin_provider, _, provider}
    source = "return await tools.request_plugin_install(#{JSON.encode!(arguments())});"
    send(provider, {:events, [call("exec", source), done()]})
    assert_receive {:host_request_ack, _, _}, 2_000
    assert_receive {:plugin_observer, _}, 2_000
    assert :ok = Conversation.cancel(conversation)
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    status = Conversation.status(conversation)
    assert status.run.state == :unknown_outcome
    assert status.retirement_evidence == []
  end

  test "an unrelated operation cannot retrieve plugin retirement" do
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    assert {:error, %Error{class: :unknown_outcome}} =
             apply(DynamicRuntime, :plugin_install_retirement, [
               runtime,
               %{invocation_id: "missing"}
             ])
  end

  test "legacy plugin waits remain unknown without registered retirement" do
    requests = :ets.new(:legacy_requests, [:public, :set])
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: LegacyPluginHost})
    {conversation, _, _} = start_run(runtime, requests, "legacy-plugin")
    assert {:ok, _} = Conversation.prompt(conversation, "legacy request")
    assert_receive {:plugin_provider, _, provider}
    send(provider, {:events, [call("request_plugin_install", arguments()), done()]})
    assert_receive {:legacy_plugin, operation, observer}
    monitor = Process.monitor(observer)
    assert :ok = Conversation.cancel(conversation)
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert_receive {:DOWN, ^monitor, :process, ^observer, _}
    assert Conversation.status(conversation).run.state == :unknown_outcome
    assert Conversation.status(conversation).retirement_evidence == []

    assert {:error, %Error{class: :unknown_outcome}} =
             DynamicRuntime.plugin_install_retirement(
               runtime,
               ToolEffects.cancellation_identity(operation)
             )
  end

  test "concurrent plugin admission and completion preserve separate requests" do
    requests = :ets.new(:concurrent_requests, [:public, :set])
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})
    {first, _, _} = start_run(runtime, requests, "concurrent-one")
    {second, _, _} = start_run(runtime, requests, "concurrent-two")
    assert {:ok, _} = Conversation.prompt(first, "first request")
    assert_receive {:plugin_provider, _, provider}
    send(provider, {:events, [call("request_plugin_install", arguments()), done()]})
    assert_receive {:host_request_ack, _, first_operation}
    assert_receive {:plugin_observer, first_observer}
    assert {:ok, _} = Conversation.prompt(second, "second request")
    assert_receive {:plugin_provider, _, provider}
    send(provider, {:events, [call("request_plugin_install", arguments()), done()]})
    assert_receive {:host_request_ack, _, second_operation}
    assert_receive {:plugin_observer, second_observer}
    assert first_operation.plugin_request_id != second_operation.plugin_request_id
    assert :ok = Conversation.cancel(first)
    eventually(fn -> Conversation.status(first).phase == :terminal end)
    refute Process.alive?(first_observer)
    assert Process.alive?(second_observer)
    send(second_observer, :installed)
    assert_receive {:plugin_provider, %{messages: messages}, provider}
    assert List.last(messages).result.request_id == second_operation.plugin_request_id
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(second).phase == :terminal end)
    assert map_size(:sys.get_state(runtime).dynamic.receipts) == 2

    assert {:error, %Error{class: :unknown_outcome}} =
             DynamicRuntime.plugin_install_retirement(
               runtime,
               ToolEffects.cancellation_identity(second_operation)
             )
  end

  defp assert_reconciled(store, original, proofs, operation) do
    host = Host.new()
    :ok = Host.put(host, {:store, "original-store"}, {EphemeralStore, store})
    run = original.run
    binding = operation.backend_context.resource_owner.session_binding

    subject = %{
      "kind" => "session",
      "scope_id" => "fixture",
      "owner_id" => binding.owner_id,
      "incarnation" => binding.incarnation
    }

    assert {:ok, obligations} =
             Reconciliation.run_obligations(run, run.incarnation, "actual-store")

    references = [
      %{
        "store_ref" => "original-store",
        "run_id" => run.run_id,
        "original_incarnation" => run.incarnation
      }
    ]

    manifest = Host.manifest(subject, references, obligations)

    observations =
      Enum.map(obligations, fn obligation ->
        fact = Host.observe(obligation, "closed")

        if obligation["kind"] == "tool" do
          invocation = obligation["identity"]["invocation_id"]
          proof = Enum.find(proofs, &(get_in(&1, ["identity", "invocation_id"]) == invocation))
          assert is_map(proof)
          reference = "effect:" <> invocation
          :ok = Host.put(host, {:evidence, reference}, proof)
          Map.put(fact, "effect_retirement_ref", reference)
        else
          fact
        end
      end)

    bundle = Host.bundle(manifest, observations)
    :ok = Host.put(host, {:evidence, "actual-closure"}, bundle)

    assert {:ok, %{"retirement" => "confirmed", "unresolved_effects" => []}} =
             Reconciliation.reconcile(
               Host.config(host),
               Host.request(manifest, "actual-retirement", "actual-closure")
             )

    assert {:ok, ^original} = EphemeralStore.load(store, run.run_id)
    tool = Enum.find(observations, &Map.has_key?(&1, "effect_retirement_ref"))
    {:ok, proof} = Host.load_evidence(host, tool["effect_retirement_ref"])

    changed_binding =
      proof
      |> put_in(["identity", "session_binding_identity", "owner_id"], "different-session")
      |> put_in(["provenance", "session_binding_identity", "owner_id"], "different-session")
      |> Map.put("stop_generation", "another-stop")
      |> Evidence.seal("retirement_digest")

    invalid =
      [
        {"generation",
         proof
         |> Map.put("stop_generation", "another-stop")
         |> Evidence.seal("retirement_digest")},
        {"digest", Map.put(proof, "retirement_digest", String.duplicate("0", 64))},
        {"unrelated",
         proof
         |> put_in(["identity", "tool_name"], "unrelated")
         |> Evidence.seal("retirement_digest")},
        {"missing", nil},
        {"binding-and-generation", changed_binding}
      ]
      |> Enum.map(fn {label, changed} -> {label, changed, tool} end)

    outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))

    invalid =
      if outer do
        changed =
          outer
          |> Map.update!("nested", fn entries ->
            Enum.map(entries, fn entry ->
              if entry["kind"] == "native_plugin_wait_retirement",
                do: put_in(entry, ["identity", "tool_call_id"], "different-nested-call"),
                else: entry
            end)
          end)
          |> Evidence.seal("retirement_digest")

        target =
          Enum.find(
            observations,
            &(get_in(&1, ["identity", "invocation_id"]) == outer["identity"]["invocation_id"])
          )

        [{"nested-identity", changed, target} | invalid]
      else
        invalid
      end

    for {label, changed, target} <- invalid do
      reference = "invalid-effect:" <> label
      if changed, do: Host.put(host, {:evidence, reference}, changed)

      facts =
        Enum.map(observations, fn fact ->
          if fact["obligation_id"] == target["obligation_id"],
            do: Map.put(fact, "effect_retirement_ref", reference),
            else: fact
        end)

      :ok = Host.put(host, {:evidence, "invalid-closure:" <> label}, Host.bundle(manifest, facts))

      assert {:error, %Error{}} =
               Reconciliation.reconcile(
                 Host.config(host),
                 Host.request(
                   manifest,
                   "invalid-retirement:" <> label,
                   "invalid-closure:" <> label
                 )
               )
    end
  end

  defp start_client(root, mode) do
    name = String.to_atom("PluginInstalled#{System.unique_integer([:positive])}")
    fixture = Path.expand("../../fixtures/resource_cancellation_mcp.py", __DIR__)

    start_supervised!(
      {Client,
       name: name,
       transport:
         {:stdio,
          command: System.find_executable("python3"),
          args: [fixture, Path.join(root, "installed-wire.jsonl")]},
       one_shot: true,
       client_info: %{"name" => "installed-plugin", "version" => "1"},
       capabilities: %{},
       protocol_version: "2025-11-25",
       timeout: 3_000},
      id: {:installed_client, mode}
    )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    name
  end

  defp start_run(runtime, requests, run, adapted \\ false) do
    session = start_supervised!({Session, owner_pid: self()}, id: {:session, run})

    installed =
      case :ets.lookup(requests, :installed) do
        [{:installed, %{client: client}}] ->
          [
            %{
              namespace: "fixture",
              name: "installed_mcp",
              backend: InstalledMcpTool,
              backend_context: %{client: client, test: self()},
              schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
              safety: %{read_only: true, retry_safe: true, parallel_safe: false}
            }
          ]

        _ ->
          []
      end

    names =
      ["exec", "wait", "request_plugin_install", "fixture::observe"] ++
        if(installed == [], do: [], else: ["fixture::installed_mcp"])

    authority = %{caller: "host", run_id: run, grants: names, tool_revision: 1}
    {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    observed = %{
      namespace: "fixture",
      name: "observe",
      backend: ObserveTool,
      backend_context: %{test: self()},
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

    contracts =
      [observed | installed] ++
        Enum.map(DynamicRuntime.contracts(%{dynamic_runtime: runtime}), fn contract ->
          %{
            contract
            | backend_context:
                Map.merge(
                  contract.backend_context,
                  %{test: self(), requests: requests}
                )
          }
        end)

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: contracts},
        authority,
        tools: names
      )

    profile =
      if adapted do
        registry =
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            descriptor =
              if descriptor.backend == Backplane.AgentRuntime.Codex.Backend,
                do: %{
                  descriptor
                  | backend:
                      if(adapted == :unregistered, do: UnregisteredAdapter, else: PostHookAdapter)
                },
                else: descriptor

            descriptor = %{
              descriptor
              | backend_context: Map.put(descriptor.backend_context, :adapter_test, self())
            }

            {name, descriptor}
          end)

        %{profile | registry: %{profile.registry | tools: registry}}
      else
        profile
      end

    {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run,
         incarnation: 1,
         session_binding: binding,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         run_timeout: 20_000,
         effect_timeout: 10_000,
         cleanup_timeout: 2_000},
        id: {:conversation, run}
      )

    {conversation, store, session}
  end

  defp arguments,
    do: %{
      "tool_type" => "mcp",
      "action_type" => "install",
      "tool_id" => "fixture",
      "suggest_reason" => "functional test"
    }

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{id: "plugin-call", name: name, arguments: arguments}
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp eventually(fun, attempts \\ 150)
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
