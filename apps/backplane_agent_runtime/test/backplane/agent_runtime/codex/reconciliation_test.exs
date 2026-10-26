Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  defmodule MovingStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def load(context, id, _opts) do
      {:ok, record} = EphemeralStore.load(context.store, id)
      reads = :ets.update_counter(context.table, :authority_reads, 1, {:authority_reads, 0})

      if reads == 1 do
        {:ok, record}
      else
        {:ok,
         %{
           record
           | revision: record.revision + 1,
             run: %{record.run | expected_revision: record.revision + 1}
         }}
      end
    end
  end

  setup do
    host = Host.new()
    {:ok, record} = Host.seed_run(host, "child-run")

    obligation =
      Evidence.obligation(
        "executor",
        %{"run_id" => "child-run", "incarnation" => 1},
        "admission:1"
      )

    manifest =
      Host.manifest(
        Host.subject(),
        [%{"store_ref" => "child-run", "run_id" => "child-run", "original_incarnation" => 1}],
        [obligation]
      )

    bundle = Host.bundle(manifest, [Host.observe(obligation)])
    :ok = Host.put(host, {:evidence, "evidence"}, bundle)

    %{
      host: host,
      record: record,
      manifest: manifest,
      bundle: bundle,
      obligation: obligation,
      request: Host.request(manifest)
    }
  end

  test "persists retirement separately and deduplicates a latest creation retry", ctx do
    assert {:ok,
            %{"revision" => 1, "closure" => "confirmed", "retirement" => "confirmed"} = receipt} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    assert receipt["historical_outcomes"] == [
             %{
               "run_id" => "child-run",
               "state" => "completed",
               "outcome_digest" => Evidence.digest(ctx.record.run.outcome)
             }
           ]

    assert {:ok, ^receipt} = Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
    assert {:ok, original} = EphemeralStore.load(ctx.host.store, "child-run")
    assert original == ctx.record
  end

  test "missing component observation persists partial progress and retains uncertainty", ctx do
    Host.put(ctx.host, {:evidence, "evidence"}, %{ctx.bundle | "observations" => []})

    assert {:error,
            %Error{class: :unknown_outcome, details: %{receipt_id: "retirement", pending: [_]}}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    assert {:ok, %{"revision" => 1, "retirement" => "pending"} = pending} =
             Host.load_receipt(ctx.host, "retirement")

    Host.put(ctx.host, {:evidence, "evidence-v2"}, ctx.bundle)

    next = %{
      ctx.request
      | "expected_revision" => pending["revision"],
        "evidence_ref" => "evidence-v2"
    }

    assert {:ok, %{"revision" => 2, "retirement" => "confirmed"} = receipt} =
             Reconciliation.reconcile(Host.config(ctx.host), next)

    assert {:ok, ^receipt} = Reconciliation.reconcile(Host.config(ctx.host), next)

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
  end

  test "a lost receipt ACK is reconciled by reading the exact committed receipt", ctx do
    Host.put(ctx.host, :lose_next_receipt_ack, true)

    assert {:ok, %{"revision" => 1, "retirement" => "confirmed"}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    assert {:ok, %{"revision" => 1}} = Host.load_receipt(ctx.host, "retirement")
  end

  test "an exact stopped provider cannot erase missing tool closure", ctx do
    tool =
      Evidence.obligation(
        "tool",
        %{
          "run_id" => "child-run",
          "incarnation" => 1,
          "step_id" => "s",
          "attempt_id" => "a",
          "invocation_id" => "mutation"
        },
        "tool-intent"
      )

    manifest =
      Host.manifest(ctx.manifest["subject"], ctx.manifest["run_refs"], [ctx.obligation, tool])

    bundle = Host.bundle(manifest, [Host.observe(ctx.obligation), Host.observe(tool)])
    Host.put(ctx.host, {:evidence, "evidence"}, bundle)

    assert {:error, %Error{class: :unknown_outcome, details: %{unresolved_effects: [_]}}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
  end

  test "conflicting identity, unsealed inventory and changed manifest are refused", ctx do
    wrong = put_in(ctx.bundle, ["observations", Access.at(0), "identity", "incarnation"], 2)
    Host.put(ctx.host, {:evidence, "evidence"}, wrong)

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    Host.put(
      ctx.host,
      {:evidence, "evidence"},
      put_in(ctx.bundle, ["inventory", "complete"], false)
    )

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    Host.put(ctx.host, {:evidence, "evidence"}, put_in(ctx.bundle, ["manifest", "run_refs"], []))

    assert {:error, %Error{class: :validation}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
  end

  test "terminal unknown lifetime can retire without changing the historical run", ctx do
    {:ok, unknown} = Host.seed_run(ctx.host, "unknown-root", state: :unknown_outcome)
    identity = %{"run_id" => "unknown-root", "incarnation" => 1}
    executor = Evidence.obligation("executor", identity, "root-admission")

    subject = %{
      "kind" => "session",
      "scope_id" => "scope",
      "owner_id" => "owner",
      "incarnation" => 1
    }

    manifest =
      Host.manifest(
        subject,
        [
          %{
            "store_ref" => "unknown-root",
            "run_id" => "unknown-root",
            "original_incarnation" => 1
          }
        ],
        [executor]
      )

    Host.put(ctx.host, {:evidence, "root"}, Host.bundle(manifest, [Host.observe(executor)]))

    assert {:ok,
            %{
              "retirement" => "confirmed",
              "historical_outcomes" => [%{"state" => "unknown_outcome"}]
            }} =
             Reconciliation.reconcile(
               Host.config(ctx.host),
               Host.request(manifest, "root-retirement", "root")
             )

    assert {:ok, ^unknown} = EphemeralStore.load(ctx.host.store, "unknown-root")
  end

  test "JSON identity and digest reject ambiguous/runtime values", ctx do
    assert {:error, %Error{class: :validation}} = Evidence.public(%{"x" => 1, x: 2})
    assert {:error, %Error{class: :validation}} = Evidence.public(%{"pid" => self()})

    assert Evidence.digest(%{"b" => [2, 1], "a" => true}) ==
             Evidence.digest(%{"a" => true, "b" => [2, 1]})

    assert {:error, %Error{class: :validation}} =
             Reconciliation.reconcile(
               Host.config(ctx.host),
               Map.put(ctx.request, "unknown", true)
             )
  end

  test "a parent observation remains pending until every owned obligation is closed", ctx do
    parent =
      Evidence.obligation(
        "session",
        %{"owner_id" => "child-owner", "incarnation" => 3},
        "session-ledger"
      )
      |> Map.put("requires", [ctx.obligation["obligation_id"]])

    manifest =
      Host.manifest(ctx.manifest["subject"], ctx.manifest["run_refs"], [ctx.obligation, parent])

    Host.put(ctx.host, {:evidence, "evidence"}, Host.bundle(manifest, [Host.observe(parent)]))

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    {:ok, receipt} = Host.load_receipt(ctx.host, "retirement")
    assert receipt["satisfied"] == []
    assert length(receipt["pending"]) == 2
  end

  test "progress cannot retract an already established closure fact", ctx do
    assert {:ok, first} = Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
    Host.put(ctx.host, {:evidence, "empty"}, %{ctx.bundle | "observations" => []})
    next = %{ctx.request | "expected_revision" => first["revision"], "evidence_ref" => "empty"}

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.reconcile(Host.config(ctx.host), next)

    assert {:ok, ^first} = Host.load_receipt(ctx.host, "retirement")
  end

  test "ownership cycles and undeclared component observations are rejected", ctx do
    cyclic = Map.put(ctx.obligation, "requires", [ctx.obligation["obligation_id"]])
    manifest = Host.manifest(ctx.manifest["subject"], ctx.manifest["run_refs"], [cyclic])
    Host.put(ctx.host, {:evidence, "cycle"}, Host.bundle(manifest, []))

    assert {:error, %Error{class: :validation}} =
             Reconciliation.reconcile(Host.config(ctx.host), %{
               ctx.request
               | "evidence_ref" => "cycle"
             })

    unknown =
      Host.observe(
        Evidence.obligation("executor", %{"run_id" => "other", "incarnation" => 1}, "other")
      )

    Host.put(ctx.host, {:evidence, "extra"}, %{ctx.bundle | "observations" => [unknown]})

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.reconcile(Host.config(ctx.host), %{
               ctx.request
               | "evidence_ref" => "extra"
             })
  end

  test "authority changing between validation and CAS prevents receipt creation", ctx do
    Host.put(ctx.host, {:store, "child-run"}, {MovingStore, ctx.host})

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    assert {:error, %Error{class: :not_found}} = Host.load_receipt(ctx.host, "retirement")
  end

  test "projection refuses a confirmed receipt after Store authority advances", ctx do
    assert {:ok, receipt} = Reconciliation.reconcile(Host.config(ctx.host), ctx.request)
    Host.put(ctx.host, :authority_reads, 1)
    Host.put(ctx.host, {:store, "child-run"}, {MovingStore, ctx.host})

    assert {:error, %Error{class: :resource_conflict}} =
             Reconciliation.load_confirmed(
               Host.config(ctx.host),
               receipt["receipt_id"],
               receipt["subject"]
             )
  end

  test "tool mutations cannot be marked successful by an unrelated subordinate receipt", ctx do
    {:ok, first} = Reconciliation.reconcile(Host.config(ctx.host), ctx.request)

    identity = %{
      "run_id" => "child-run",
      "incarnation" => 1,
      "step_id" => "step",
      "attempt_id" => "attempt",
      "invocation_id" => "mutation",
      "receipt_id" => first["receipt_id"],
      "subject" => first["subject"]
    }

    tool = Evidence.obligation("tool", identity, "effect-ledger")

    manifest =
      Host.manifest(ctx.manifest["subject"], ctx.manifest["run_refs"], [ctx.obligation, tool])

    Host.put(
      ctx.host,
      {:evidence, "tool"},
      Host.bundle(manifest, [Host.observe(ctx.obligation), Host.observe(tool)])
    )

    assert {:error, %Error{class: :unknown_outcome, details: %{unresolved_effects: [_]}}} =
             Reconciliation.reconcile(
               Host.config(ctx.host),
               Host.request(manifest, "tool", "tool")
             )
  end

  test "completed or cleared Provider attempts remain required lifetime observations", ctx do
    for ending <- [:completed, :cancelled] do
      id = "provider-#{ending}"
      run = %{run_id: id, incarnation: 1, expected_revision: 0, state: :queued}

      commit = fn run, command ->
        EphemeralStore.store(ctx.host.store, run, %{command: command})
      end

      load = fn ->
        {:ok, %{run: run}} = EphemeralStore.load(ctx.host.store, id)
        run
      end

      assert {:ok, _} = commit.(run, {:admit, 1, %{state: :running}})
      identity = %{run_id: id, incarnation: 1, step_id: "step", attempt_id: "original"}
      assert {:ok, _} = commit.(load.(), {:provider_started, 2, identity})

      if ending == :completed do
        input = Map.merge(identity, %{final?: true, outcome: "answer"})
        assert {:ok, _} = commit.(load.(), {:provider_completed, 3, input})
      else
        assert {:ok, _} = commit.(load.(), {:cancel, 3})
        settling = load.()

        assert {:ok, _} =
                 commit.(
                   settling,
                   {:cleanup_settled, 4,
                    %{
                      certainty: :confirmed,
                      settled: Backplane.AgentRuntime.Kernel.cleanup_requirements(settling)
                    }}
                 )
      end

      current = load.()
      assert current.active_provider == nil
      assert {:ok, obligations} = Reconciliation.run_obligations(current, 1, "original-ledger")

      assert Enum.any?(
               obligations,
               &(&1["kind"] == "provider" and &1["identity"]["attempt_id"] == "original")
             )

      refs = [%{"store_ref" => id, "run_id" => id, "original_incarnation" => 1}]

      subject = %{
        "kind" => "session",
        "scope_id" => "scope",
        "owner_id" => id,
        "incarnation" => 1
      }

      executor =
        Evidence.obligation("executor", %{"run_id" => id, "incarnation" => 1}, "original-ledger")

      omitted = Host.manifest(subject, refs, [executor])
      Host.put(ctx.host, {:evidence, id}, Host.bundle(omitted, [Host.observe(executor)]))

      assert {:error, %Error{class: :unknown_outcome}} =
               Reconciliation.reconcile(Host.config(ctx.host), Host.request(omitted, id, id))
    end
  end
end
