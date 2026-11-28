Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)
Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.HistoricalContinuationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error, Store, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Reconciliation, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Continuation, Evidence}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:fresh_provider_after_owner_loss, request})
      [%{type: :response_completed, message: %{role: :assistant, content: "Fresh answer"}}]
    end
  end

  setup %{tmp_dir: path} do
    {:ok, host} = Host.open(path)
    on_exit(fn -> Host.cleanup(host) end)
    original = seed_unknown_run(host)

    request = %{
      "schema_version" => 1,
      "mode" => "historical_owner_loss",
      "root_agent_id" => "r",
      "subject" => %{
        "kind" => "session",
        "scope_id" => "original-thread",
        "owner_id" => "original-session",
        "incarnation" => 69
      },
      "source" => %{
        "run_id" => "source",
        "original_incarnation" => 1,
        "store_ref" => "source-store"
      },
      "evidence_ref" => "historical-closure",
      "instruction_ref" => "continue-original-thread"
    }

    %{host: host, config: Host.config(host), original: original, path: path, request: request}
  end

  test "surviving durable evidence admits fresh work without old owner inventories", ctx do
    evidence = historical_evidence(ctx)
    :ok = Host.put(ctx.host, {:evidence, ctx.request["evidence_ref"]}, evidence)
    assert {:ok, decision} = Continuation.prepare(ctx.config, ctx.request)
    assert decision["mode"] == "historical_owner_loss"
    assert decision["evidence_ref"] == ctx.request["evidence_ref"]
    assert decision["evidence_digest"] == Evidence.digest(evidence)
    refute Map.has_key?(decision, "receipt_id")
    refute Map.has_key?(decision, "receipt_digest")
    assert decision["subject"] == ctx.request["subject"]
    assert decision["source"] == ctx.request["source"]

    assert [%{"tool_call_id" => "lost-call", "tool_name" => "skills::list"}] =
             decision["unresolved_tools"]

    assert %{"state" => "unknown_outcome"} = decision["historical_outcome"]
    assert %{"run_id" => fresh, "original_incarnation" => incarnation} = decision["target"]
    assert fresh != ctx.original.run.run_id

    session =
      start_supervised!(
        {Session,
         owner_pid: self(),
         recovery: ctx.config,
         recovery_scope_id: ctx.request["subject"]["scope_id"]}
      )

    authority = %{caller: "host", run_id: fresh, grants: []}
    assert {:ok, binding} = Session.bind(session, authority, incarnation: incarnation)
    assert binding.owner_id != ctx.request["subject"]["owner_id"]
    notice = decision["model_notice"]

    conversation =
      start_supervised!(
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

    assert {:ok, _} = Conversation.prompt(conversation, "Continue this thread")

    assert_receive {:fresh_provider_after_owner_loss, %{run_id: ^fresh, messages: messages}},
                   2_000

    assert [%{content: ^notice}, %{content: "Continue this thread"}] = messages
    assert_receive {:agent_runtime, ^fresh, %{type: :run_completed}}, 2_000
    assert {:ok, ctx.original} == Host.load(ctx.host, "source")
    assert ctx.original.run.tool_results == %{"settled" => %{content: "Already saved output"}}
    assert ctx.original.run.context.goal_attribution.goal_id == "original-goal"
  end

  test "concurrent retries select one target and reject a different instruction", ctx do
    :ok = Host.put(ctx.host, {:evidence, ctx.request["evidence_ref"]}, historical_evidence(ctx))

    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> Continuation.prepare(ctx.config, ctx.request) end) end)
      |> Task.await_many()

    assert [{:ok, decision}] = Enum.uniq(results)
    assert {:ok, ^decision} = Continuation.prepare(ctx.config, ctx.request)

    assert {:error, %Error{class: :resource_conflict}} =
             Continuation.prepare(ctx.config, %{
               ctx.request
               | "instruction_ref" => "different-instruction"
             })

    legacy_request =
      ctx.request
      |> Map.take(~w(schema_version subject source instruction_ref))
      |> Map.put("receipt_id", "unavailable-original-session")
      |> Map.put("closure_evidence_ref", "unavailable-original-closure")

    assert {:error, %Error{class: :resource_conflict}} =
             Continuation.prepare(ctx.config, legacy_request)

    assert {:ok, ^decision} = Host.load_continuation(ctx.host, decision["continuation_id"])
    assert {:ok, ctx.original} == Host.load(ctx.host, "source")
  end

  test "definite refusal and a lost acknowledgement remain retryable after reopening", ctx do
    :ok = Host.put(ctx.host, {:evidence, ctx.request["evidence_ref"]}, historical_evidence(ctx))
    :ok = Host.fault_next(ctx.host, :continuation, :refuse)

    assert {:error, %Error{class: :unknown_outcome}} =
             Continuation.prepare(ctx.config, ctx.request)

    assert {:ok, ctx.original} == Host.load(ctx.host, "source")

    :ok = Host.fault_next(ctx.host, :continuation, :lose_ack)
    assert {:ok, decision} = Continuation.prepare(ctx.config, ctx.request)
    :ok = Host.cleanup(ctx.host)
    assert {:ok, reopened} = Host.open(ctx.path)
    on_exit(fn -> Host.cleanup(reopened) end)

    assert {:ok, ^decision} = Continuation.prepare(Host.config(reopened), ctx.request)
    assert {:ok, ctx.original} == Host.load(reopened, "source")
  end

  test "missing original cessation evidence refuses continuation without changing the source",
       ctx do
    evidence = historical_evidence(ctx)

    for field <- ~w(root_admission_ref executor_ref provider_refs host_refs managers) do
      ref = "missing-" <> field
      :ok = Host.put(ctx.host, {:evidence, ref}, Map.delete(evidence, field))

      assert {:error, %Error{class: :validation}} =
               Continuation.prepare(ctx.config, %{ctx.request | "evidence_ref" => ref})

      assert {:ok, ctx.original} == Host.load(ctx.host, "source")
    end

    assert {:error, %Error{class: :not_found}} =
             Continuation.prepare(ctx.config, %{ctx.request | "evidence_ref" => "absent-evidence"})
  end

  test "empty or foreign component inventories cannot attest to the original generation", ctx do
    evidence = historical_evidence(ctx)

    for {field, value} <- [
          {"provider_refs", []},
          {"host_refs", []},
          {"managers", []},
          {"authority", %{evidence["authority"] | "fences" => []}},
          {"root_agent_id", "foreign-thread-root"},
          {"subject", put_in(evidence["subject"], ["owner_id"], "foreign-owner")}
        ] do
      ref = "invalid-" <> field
      :ok = Host.put(ctx.host, {:evidence, ref}, %{evidence | field => value})

      assert {:error, %Error{class: class, message: message}} =
               Continuation.prepare(ctx.config, %{ctx.request | "evidence_ref" => ref})

      assert class in [:validation, :resource_conflict, :unknown_outcome]
      assert is_binary(message) and message != ""

      assert {:ok, ctx.original} == Host.load(ctx.host, "source")
    end
  end

  test "stale authoritative Store revision cannot be accepted using old closure facts", ctx do
    evidence = historical_evidence(ctx)
    :ok = Host.put(ctx.host, {:evidence, ctx.request["evidence_ref"]}, evidence)
    assert {:ok, _} = Store.fence(Host, ctx.host, "source", ctx.original.revision, 2, 3)
    assert {:ok, after_fence} = Host.load(ctx.host, "source")

    assert {:error, %Error{class: :resource_conflict}} =
             Continuation.prepare(ctx.config, ctx.request)

    assert {:ok, ^after_fence} = Host.load(ctx.host, "source")
  end

  test "contradictory durable component records cannot substitute for original cessation", ctx do
    evidence = historical_evidence(ctx)

    cases = [
      {["provider_refs", Access.at(0)], "provider-stop", ["identity", "attempt_id"],
       "foreign-attempt"},
      {["executor_ref"], "executor-stop", ["reason"], ":killed"},
      {["host_refs", Access.at(0)], "host-retirement",
       ["bindings", Access.at(0), "run_incarnation"], 2},
      {["host_refs", Access.at(0)], "host-retirement", ["native", Access.at(0), "status"],
       "unconfirmed"},
      {["host_refs", Access.at(0)], "host-retirement", ["async_hooks", "status"], "pending"},
      {["host_refs", Access.at(0)], "host-retirement", ["session_end", "dispatch"], "pending"},
      {["managers", Access.at(0), "acknowledgement_ref"], "manager-ack", ["receipt_digest"],
       "wrong-receipt"},
      {["host_refs", Access.at(0)], "host-retirement", ["native"],
       [%{"status" => "confirmed", "owner_id" => "original-session", "session_incarnation" => 69}]}
    ]

    for {{reference_path, original_ref, fact_path, value}, index} <- Enum.with_index(cases) do
      ref = "contradictory-fact-#{index}"
      assert {:ok, fact} = Host.load_evidence(ctx.host, original_ref)
      :ok = Host.put(ctx.host, {:evidence, ref}, put_in(fact, fact_path, value))
      bundle_ref = "contradictory-bundle-#{index}"
      :ok = Host.put(ctx.host, {:evidence, bundle_ref}, put_in(evidence, reference_path, ref))

      assert {:error, %Error{class: class, message: message}} =
               Continuation.prepare(ctx.config, %{ctx.request | "evidence_ref" => bundle_ref})

      assert class in [:validation, :resource_conflict, :unknown_outcome]
      assert is_binary(message) and message != ""

      assert {:ok, ctx.original} == Host.load(ctx.host, "source")
    end
  end

  test "incomplete result inventories and inconsistent Provider keys cannot establish recovery",
       ctx do
    missing_results = %{ctx.original | run: Map.delete(ctx.original.run, :tool_results)}

    inconsistent_provider =
      put_in(
        ctx.original,
        [:run, :provider_attempts, "provider-attempt", :attempt_id],
        "foreign-key"
      )

    for {name, original, component} <- [
          {"missing-results", missing_results, "tool_inventory"},
          {"inconsistent-provider", inconsistent_provider, "provider_generation"}
        ] do
      {:ok, host} = Host.open(Path.join(ctx.path, name))
      on_exit(fn -> Host.cleanup(host) end)
      :ok = Host.put(host, {:run, "source"}, original)
      isolated = %{ctx | host: host, config: Host.config(host), original: original}
      evidence = historical_evidence(isolated)
      :ok = Host.put(host, {:evidence, ctx.request["evidence_ref"]}, evidence)

      assert {:error, %Error{class: :unknown_outcome, details: %{component: ^component}}} =
               Continuation.prepare(isolated.config, ctx.request)

      assert {:ok, ^original} = Host.load(host, "source")
    end
  end

  defp historical_evidence(ctx) do
    subject = ctx.request["subject"]
    source = ctx.request["source"]

    identity = %{
      "root_header_id" => subject["scope_id"],
      "transcript_header_id" => subject["scope_id"],
      "child_session_id" => nil,
      "host_lifetime_id" => "original-host"
    }

    binding =
      Map.merge(identity, %{
        "run_id" => source["run_id"],
        "run_incarnation" => source["original_incarnation"],
        "native_owner_id" => subject["owner_id"],
        "native_session_incarnation" => subject["incarnation"]
      })

    earlier_binding = %{
      binding
      | "run_id" => "earlier-run",
        "run_incarnation" => 3,
        "native_owner_id" => "earlier-native-owner",
        "native_session_incarnation" => 68
    }

    provider = ctx.original.run.provider_attempts["provider-attempt"]
    {:ok, provider} = Evidence.public(provider)

    facts = %{
      "root-admission" => %{
        "run_id" => source["run_id"],
        "incarnation" => source["original_incarnation"],
        "store_ref" => source["store_ref"]
      },
      "executor-stop" => %{
        "run_id" => source["run_id"],
        "incarnation" => source["original_incarnation"],
        "status" => "stopped",
        "reason" => ":normal"
      },
      "provider-stop" => %{
        "identity" => provider,
        "status" => "stopped",
        "exit_kind" => "normal",
        "observer" => "original-provider-monitor"
      },
      "host-retirement" => %{
        "identity" => identity,
        "bindings" => [binding, earlier_binding],
        "native" => [
          %{
            "status" => "confirmed",
            "owner_id" => subject["owner_id"],
            "session_incarnation" => subject["incarnation"]
          },
          %{
            "status" => "confirmed",
            "owner_id" => "earlier-native-owner",
            "session_incarnation" => 68
          }
        ],
        "async_hooks" => %{"status" => "confirmed"},
        "session_end" => %{
          "status" => "confirmed",
          "dispatch" => "completed",
          "outcome" => "proceed",
          "warnings" => []
        }
      }
    }

    Enum.each(facts, fn {ref, fact} -> :ok = Host.put(ctx.host, {:evidence, ref}, fact) end)

    manager = %{
      "kind" => "manager",
      "scope_id" => subject["scope_id"],
      "manager_id" => "original-manager",
      "root_agent_id" => ctx.request["root_agent_id"]
    }

    manifest = Shapes.manifest(manager)
    :ok = Host.put(ctx.host, {:evidence, "manager-closure"}, Shapes.bundle(manifest))

    assert {:ok, receipt} =
             Reconciliation.reconcile(
               ctx.config,
               Shapes.request(manifest, "manager", "manager-closure")
             )

    acknowledgement = %{
      "manager_id" => manager["manager_id"],
      "receipt_id" => receipt["receipt_id"],
      "receipt_digest" => receipt["receipt_digest"],
      "revision" => receipt["revision"],
      "status" => "confirmed"
    }

    :ok = Host.put(ctx.host, {:evidence, "manager-ack"}, acknowledgement)

    fences =
      for %{fence: fence} <- ctx.original.journal do
        {:ok, public} = Evidence.public(fence)
        Map.merge(public, %{"run_id" => source["run_id"], "source_ref" => "original-store-fence"})
      end

    %{
      "schema_version" => 1,
      "subject" => subject,
      "source" => source,
      "root_agent_id" => ctx.request["root_agent_id"],
      "authority" => %{
        "revision" => ctx.original.revision,
        "incarnation" => ctx.original.run.incarnation,
        "fences" => fences
      },
      "root_admission_ref" => "root-admission",
      "executor_ref" => "executor-stop",
      "provider_refs" => ["provider-stop"],
      "host_refs" => ["host-retirement"],
      "managers" => [
        %{"receipt_id" => receipt["receipt_id"], "acknowledgement_ref" => "manager-ack"}
      ]
    }
  end

  defp seed_unknown_run(host) do
    provider = %{
      run_id: "source",
      incarnation: 1,
      step_id: "step",
      attempt_id: "provider-attempt"
    }

    budget = %{quota: 10, used: 2}

    settled =
      Map.merge(provider, %{
        invocation_id: "settled",
        tool_call_id: "settled-call",
        tool_name: "read_file",
        tool_revision: 1,
        arguments: %{"path" => "saved.txt"}
      })

    lost = %{
      settled
      | invocation_id: "lost",
        tool_call_id: "lost-call",
        tool_name: "skills::list",
        arguments: %{}
    }

    invocation = fn tool ->
      Map.merge(tool, %{
        execution_budget: budget,
        execution_intent: %{
          type: :tool,
          status: :started,
          operation: tool,
          reservation: %{reservation_id: "tool:" <> tool.invocation_id}
        }
      })
    end

    source = %{
      run_id: "source",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: :infinity,
      execution_budget: budget,
      children: [],
      context: %{
        conversation: %{messages: [%{role: :user, content: "Keep this context"}], goal_outbox: []},
        goal_attribution: %{goal_id: "original-goal", run_id: "source", incarnation: 1}
      }
    }

    commands = [
      {:admit, 1, %{state: :running}},
      {:provider_started, 2, provider},
      {:provider_completed, 3, Map.merge(provider, %{final?: false, result: %{}})},
      {:tool_invoked, 4, invocation.(settled)},
      {:tool_completed, 5, Map.put(settled, :result, %{content: "Already saved output"})},
      {:tool_invoked, 6, invocation.(lost)}
    ]

    active =
      Enum.reduce(commands, %{run: source}, fn command, %{run: run} ->
        assert {:ok, _} = Store.store(Host, host, run, %{command: command})
        assert {:ok, snapshot} = Host.load(host, "source")
        snapshot
      end)

    assert {:ok, _} = Store.fence(Host, host, "source", active.revision, 1, 2)
    assert {:ok, %{run: fenced}} = Host.load(host, "source")
    assert {:ok, _} = Store.store(Host, host, fenced, %{command: {:cancel, 7}})
    assert {:ok, %{run: cancelling}} = Host.load(host, "source")

    assert {:ok, _} =
             Store.store(Host, host, cancelling, %{
               command:
                 {:cleanup_settled, 8,
                  %{certainty: :uncertain, evidence: %{reason: "tool acknowledgement was lost"}}}
             })

    assert {:ok, %{run: %{state: :unknown_outcome, incarnation: 2}} = snapshot} =
             Host.load(host, "source")

    snapshot
  end
end
