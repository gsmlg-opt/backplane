Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)
Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ContinuationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Reconciliation, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Continuation, Evidence}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:fresh_provider, request})
      [%{type: :response_completed, message: %{role: :assistant, content: "fresh answer"}}]
    end
  end

  setup %{tmp_dir: path} do
    {:ok, host} = Host.open(path)
    on_exit(fn -> Host.cleanup(host) end)
    old = seed_unknown_run(host)
    source = %{"run_id" => "source", "original_incarnation" => 1, "store_ref" => "source-store"}

    owner = %{
      "kind" => "session",
      "scope_id" => "thread",
      "owner_id" => "old",
      "incarnation" => 2
    }

    registry = Map.put(owner, "kind", "registry_owner")

    manager = %{
      "kind" => "manager",
      "scope_id" => "thread",
      "manager_id" => "m",
      "root_agent_id" => "r"
    }

    registry = retire_subordinate(host, registry)
    manager = retire_subordinate(host, manager)
    {:ok, run_obligations} = Reconciliation.run_obligations(old.run, 1, "run-admission")
    obligations = run_obligations ++ [registry, manager]
    manifest = Shapes.manifest(owner, [source], obligations)

    observations =
      Enum.flat_map(obligations, fn
        %{"kind" => "tool"} ->
          []

        %{"identity" => %{"receipt_id" => id}} = obligation ->
          [%{Shapes.observe(obligation, "closed") | "source_ref" => id}]

        obligation ->
          [Shapes.observe(obligation)]
      end)

    bundle = Shapes.bundle(manifest, observations)
    :ok = Host.put(host, {:evidence, "root-evidence"}, bundle)

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(
               Host.config(host),
               Shapes.request(manifest, "root", "root-evidence")
             )

    {:ok, receipt} = Host.load_receipt(host, "root")
    assert [%{"kind" => "tool"}] = receipt["pending"]
    assert receipt["closure"] == "pending"
    assert receipt["retirement"] == "pending"

    proof = %{
      "schema_version" => 1,
      "subject" => owner,
      "source" => source,
      "receipt_digest" => receipt["receipt_digest"],
      "components" => %{
        "root_admission" => %{"status" => "admitted", "source_ref" => "root-admission"},
        "local_execution" => %{"status" => "stopped", "source_ref" => "joined-local-workers"},
        "async_hooks" => %{"status" => "closed", "source_ref" => "hooks-ack"},
        "session_end" => %{"status" => "closed", "source_ref" => "session-end-ack"}
      }
    }

    request = %{
      "schema_version" => 1,
      "subject" => owner,
      "source" => source,
      "receipt_id" => "root",
      "closure_evidence_ref" => "closure",
      "instruction_ref" => "user-continue-1"
    }

    %{
      host: host,
      config: Host.config(host),
      request: request,
      proof: proof,
      receipt: receipt,
      bundle: bundle,
      old: old,
      path: path
    }
  end

  @tag capture_log: true
  test "unknown history stays immutable and the durable decision selects one fresh run", ctx do
    :ok = Host.put(ctx.host, {:evidence, "closure"}, ctx.proof)

    results =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Continuation.prepare(ctx.config, ctx.request) end) end)

    assert [{:ok, decision}] = results |> Task.await_many() |> Enum.uniq()
    assert {:ok, ^decision} = Continuation.prepare(ctx.config, ctx.request)

    assert {:error, %Error{class: :resource_conflict}} =
             Continuation.prepare(ctx.config, %{ctx.request | "instruction_ref" => "other-click"})

    assert %{
             "historical_outcome" => %{"state" => "unknown_outcome"},
             "model_notice" => notice,
             "unresolved_tools" => [
               %{"tool_call_id" => "old-provider-call", "tool_name" => "read"}
             ],
             "target" => %{"run_id" => fresh, "original_incarnation" => incarnation}
           } = decision

    assert fresh != "source"
    assert {:ok, ^decision} = Host.load_continuation(ctx.host, decision["continuation_id"])

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.load_confirmed(ctx.config, "root", ctx.request["subject"])

    {:ok, session} =
      start_supervised(
        {Session, owner_pid: self(), recovery: ctx.config, recovery_scope_id: "thread"}
      )

    authority = %{caller: "host", run_id: fresh, grants: []}
    assert {:ok, binding} = Session.bind(session, authority, incarnation: incarnation)
    assert binding.owner_id != ctx.request["subject"]["owner_id"]

    {:ok, conversation} =
      start_supervised(
        {Conversation,
         run_id: fresh,
         incarnation: incarnation,
         session_binding: binding,
         store: Host,
         context: ctx.host,
         authority: authority,
         registry: %ToolRegistry{},
         tools: [],
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         messages: [%{role: :user, content: notice}]}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "fresh work")
    assert_receive {:fresh_provider, %{run_id: ^fresh, messages: messages}}, 2_000
    assert [%{role: :user, content: ^notice}, %{role: :user, content: "fresh work"}] = messages
    assert_receive {:agent_runtime, ^fresh, %{type: :run_completed}}, 2_000

    assert {:ok, ctx.old} == Host.load(ctx.host, "source")
    assert {:ok, ctx.receipt} == Host.load_receipt(ctx.host, "root")
  end

  test "missing local exit, async-hook or SessionEnd fact blocks even after reopening", ctx do
    for component <- ~w(root_admission local_execution async_hooks session_end) do
      ref = "missing-" <> component
      proof = update_in(ctx.proof["components"], &Map.delete(&1, component))
      :ok = Host.put(ctx.host, {:evidence, ref}, proof)

      assert {:error, %Error{}} =
               Continuation.prepare(ctx.config, %{ctx.request | "closure_evidence_ref" => ref})
    end

    :ok = Host.cleanup(ctx.host)
    {:ok, reopened} = Host.open(ctx.path)
    on_exit(fn -> Host.cleanup(reopened) end)
    assert {:error, %Error{}} = Continuation.prepare(Host.config(reopened), ctx.request)
  end

  test "storage refusal blocks admission and a lost write acknowledgement is read back", ctx do
    :ok = Host.put(ctx.host, {:evidence, "closure"}, ctx.proof)
    :ok = Host.fault_next(ctx.host, :continuation, :refuse)

    assert {:error, %Error{class: :unknown_outcome}} =
             Continuation.prepare(ctx.config, ctx.request)

    :ok = Host.fault_next(ctx.host, :continuation, :lose_ack)
    assert {:ok, decision} = Continuation.prepare(ctx.config, ctx.request)
    assert {:ok, ^decision} = Continuation.prepare(ctx.config, ctx.request)

    :ok = Host.cleanup(ctx.host)
    {:ok, reopened} = Host.open(ctx.path)
    on_exit(fn -> Host.cleanup(reopened) end)
    assert {:ok, ^decision} = Continuation.prepare(Host.config(reopened), ctx.request)
  end

  test "a live local worker leaves the original execution generation fenced", ctx do
    {worker, monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(worker, :stop) end)
    assert Process.alive?(worker)
    live_proof = put_in(ctx.proof, ["components", "local_execution", "status"], "running")
    :ok = Host.put(ctx.host, {:evidence, "live-execution"}, live_proof)

    assert {:error, %Error{class: :unknown_outcome, details: %{component: "local_execution"}}} =
             Continuation.prepare(ctx.config, %{
               ctx.request
               | "closure_evidence_ref" => "live-execution"
             })

    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    :ok = Host.put(ctx.host, {:evidence, "closure"}, ctx.proof)
    assert {:ok, _} = Continuation.prepare(ctx.config, ctx.request)
  end

  test "root evidence cannot substitute for a missing Provider stop", ctx do
    missing = Enum.reject(ctx.bundle["observations"], &(&1["identity"]["attempt_id"] == "a"))

    :ok =
      Host.put(ctx.host, {:evidence, "provider-missing"}, %{
        ctx.bundle
        | "observations" => missing
      })

    request = Shapes.request(ctx.bundle["manifest"], "provider-missing", "provider-missing")

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(ctx.config, request)

    assert {:ok, receipt} = Host.load_receipt(ctx.host, "provider-missing")

    :ok =
      Host.put(ctx.host, {:evidence, "closure"}, %{
        ctx.proof
        | "receipt_digest" => receipt["receipt_digest"]
      })

    assert {:error,
            %Error{
              class: :unknown_outcome,
              message: "a non-tool lifetime obligation remains pending"
            }} =
             Continuation.prepare(ctx.config, %{ctx.request | "receipt_id" => "provider-missing"})
  end

  defp retire_subordinate(host, subject) do
    id = subject["kind"]
    manifest = Shapes.manifest(subject)
    :ok = Host.put(host, {:evidence, id}, Shapes.bundle(manifest))

    assert {:ok, _} =
             Reconciliation.reconcile(Host.config(host), Shapes.request(manifest, id, id))

    Evidence.obligation(
      id,
      %{
        "subject" => subject,
        "receipt_id" => id,
        "manifest_digest" => manifest["manifest_digest"]
      },
      "session-owned"
    )
  end

  defp seed_unknown_run(host) do
    provider = %{run_id: "source", incarnation: 1, step_id: "s", attempt_id: "a"}

    tool =
      Map.merge(provider, %{
        invocation_id: "outer",
        tool_call_id: "old-provider-call",
        tool_name: "read",
        tool_revision: 1,
        arguments: %{}
      })

    budget = %{quota: 10, used: 2}

    intent = %{
      type: :tool,
      status: :started,
      operation: tool,
      reservation: %{reservation_id: "tool:outer"}
    }

    source = %{
      run_id: "source",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: :infinity,
      execution_budget: budget,
      children: [],
      context: %{conversation: %{messages: [], goal_outbox: []}}
    }

    commands = [
      {:admit, 1, %{state: :running}},
      {:provider_started, 2, provider},
      {:provider_completed, 3, Map.merge(provider, %{final?: false, result: %{}})},
      {:tool_invoked, 4, Map.merge(tool, %{execution_intent: intent, execution_budget: budget})},
      {:cancel, 5},
      {:cleanup_settled, 6, %{certainty: :uncertain, evidence: %{reason: "completion missing"}}}
    ]

    Enum.reduce(commands, %{run: source}, fn command, %{run: run} ->
      assert {:ok, _} = Host.store(host, run, %{command: command})
      assert {:ok, next} = Host.load(host, "source")
      next
    end)
  end
end
