Code.require_file("../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.ResourceScopeRetirementRecordTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  test "portable scope retirement preserves completed and cancelled request identities" do
    {operation, proof} = fixture()
    assert {:ok, ^proof} = ToolEffects.validate_retirement_record(proof, operation)

    assert Enum.map(proof["cancellation"]["slots"], & &1["receipt"]["terminal"]) ==
             ["completed", "cancelled"]
  end

  test "portable scope proof requires every ordered slot and its actual local cleanup" do
    {operation, proof} = fixture()

    mutations = [
      fn p -> put_in(p, ["executor_down"], false) end,
      fn p -> put_in(p, ["resources"], "uncertain") end,
      fn p -> put_in(p, ["cancellation", "stop_generation"], "different-stop") end,
      fn p -> put_in(p, ["provenance", "session_binding_identity", "owner_id"], "foreign") end,
      fn p -> put_in(p, ["cancellation", "gate"], "open") end,
      fn p -> put_in(p, ["cancellation", "inventory_count"], 1) end,
      fn p -> put_in(p, ["cancellation", "slots"], tl(p["cancellation"]["slots"])) end,
      fn p -> put_in(p, ["cancellation", "slots"], Enum.reverse(p["cancellation"]["slots"])) end,
      fn p -> update_slot(p, 1, &put_in(&1, ["identity", "client_incarnation"], "foreign")) end,
      fn p -> update_slot(p, 1, &put_in(&1, ["receipt", "local_cleanup"], "uncertain")) end,
      fn p ->
        update_slot(p, 1, &put_in(&1, ["receipt", "cleanup_evidence", "workers_down"], false))
      end,
      fn p ->
        update_slot(p, 1, &put_in(&1, ["receipt", "cleanup_evidence", "transport"], "pending"))
      end,
      fn p -> update_slot(p, 1, &put_in(&1, ["receipt", "request_ids"], [])) end,
      fn p -> update_slot(p, 1, &put_in(&1, ["receipt", "request_ids"], ["other-wire"])) end,
      fn p -> update_slot(p, 1, &Map.put(&1, "extra", true)) end,
      fn p -> Map.put(p, "extra", true) end
    ]

    for mutate <- mutations do
      changed = proof |> mutate.() |> reseal()

      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_retirement_record(changed, operation)
    end
  end

  test "duplicate request inventory cannot be made valid by resealing all digests" do
    {operation, proof} = fixture()
    [first, _second] = proof["cancellation"]["slots"]

    duplicate =
      proof
      |> put_in(["cancellation", "slots"], [first, Map.put(first, "index", 2)])
      |> reseal()

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_retirement_record(duplicate, operation)
  end

  test "outer Code Mode references resource retirement without replacing its identity" do
    {operation, nested} = fixture()
    outer = %{operation | invocation_id: "outer", tool_name: "exec", arguments: "source"}
    {:ok, identity} = Evidence.public(ToolEffects.cancellation_identity(outer))

    proof =
      %{
        "schema_version" => 1,
        "record_type" => "code_mode_retirement",
        "identity" => identity,
        "stop_generation" => "stop",
        "provenance" => %{"session_binding_identity" => identity["session_binding_identity"]},
        "executor_down" => true,
        "resources" => "confirmed",
        "nested" => [
          %{
            "kind" => "resource_scope_retirement",
            "identity" => Map.put(nested["identity"], "enclosing_invocation_id", "outer"),
            "evidence_digest" => nested["retirement_digest"]
          }
        ],
        "local_cleanup" => "confirmed",
        "outcome" => "unknown"
      }
      |> Evidence.seal("retirement_digest")

    assert {:ok, ^proof} = ToolEffects.validate_retirement_record(proof, outer)
  end

  test "reconciliation requires the exact scope inventory retained by the authoritative Store" do
    {operation, proof} = fixture()
    host = retirement_host(operation, proof)
    assert {:ok, %{"retirement" => "confirmed"}} = reconcile(host, proof, "original")

    changed =
      proof
      |> update_slot(1, fn slot ->
        slot
        |> put_in(["identity", "client_incarnation"], "replacement-client")
        |> put_in(["receipt", "client_incarnation"], "replacement-client")
      end)
      |> reseal()

    assert {:ok, ^changed} = ToolEffects.validate_retirement_record(changed, operation)

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile(host, changed, "resealed-replacement")

    unretained = retirement_host(operation, nil)

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile(unretained, proof, "unretained")
  end

  # These are validator unit records, not observations of a real resource effect.
  # Lifecycle fixtures separately produce their own records through Conversation.
  defp retirement_host(operation, proof) do
    host = Host.new()

    initial = %{
      run_id: operation.run_id,
      incarnation: operation.incarnation,
      expected_revision: 0,
      state: :queued,
      context: %{execution_mode: :headless}
    }

    intent = %{
      type: :tool,
      status: :started,
      operation: operation,
      reservation: %{reservation_id: "tool:#{operation.invocation_id}"}
    }

    commands = [
      {:admit, 1, %{state: :running}},
      {:host_step_started, 2, Map.put(operation, :catalog, %{})},
      {:tool_invoked, 3,
       Map.merge(operation, %{
         execution_intent: intent,
         execution_budget: %{quota: 10, used: 1}
       })},
      {:cancel, 4},
      {:cleanup_settled, 5,
       %{certainty: :confirmed, evidence: %{retirement_evidence: List.wrap(proof)}}}
    ]

    _settled =
      Enum.reduce(commands, initial, fn command, run ->
        command =
          case command do
            {:cleanup_settled, at, input} ->
              {:cleanup_settled, at,
               Map.put(input, :settled, Backplane.AgentRuntime.Kernel.cleanup_requirements(run))}

            _ ->
              command
          end

        assert {:ok, _} = EphemeralStore.store(host.store, run, %{command: command})
        assert {:ok, %{run: next}} = EphemeralStore.load(host.store, run.run_id)
        next
      end)

    host
  end

  defp reconcile(host, proof, id) do
    assert {:ok, %{run: run}} = EphemeralStore.load(host.store, proof["identity"]["run_id"])

    assert {:ok, obligations} =
             Reconciliation.run_obligations(run, run.incarnation, "unit-record")

    references = [
      %{"store_ref" => run.run_id, "run_id" => run.run_id, "original_incarnation" => 1}
    ]

    manifest = Host.manifest(Host.subject(run.run_id), references, obligations)
    :ok = Host.put(host, {:evidence, "effect:" <> id}, proof)

    observations =
      Enum.map(obligations, fn obligation ->
        observed = Host.observe(obligation, "closed")

        if obligation["kind"] == "tool",
          do: Map.put(observed, "effect_retirement_ref", "effect:" <> id),
          else: observed
      end)

    :ok = Host.put(host, {:evidence, id}, Host.bundle(manifest, observations))
    Reconciliation.reconcile(Host.config(host), Host.request(manifest, id, id))
  end

  defp fixture do
    operation = %{
      run_id: "run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "resource",
      tool_name: "list_mcp_resources",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      arguments: %{},
      session_binding_identity: %{
        run_id: "run",
        owner_id: "owner",
        incarnation: 1,
        run_incarnation: 1
      }
    }

    {:ok, identity} = Evidence.public(ToolEffects.cancellation_identity(operation))
    slots = [slot(1, "completed"), slot(2, "cancelled")]

    proof =
      %{
        "schema_version" => 1,
        "record_type" => "resource_scope_retirement",
        "identity" => identity,
        "stop_generation" => "stop",
        "provenance" => %{"session_binding_identity" => identity["session_binding_identity"]},
        "cancellation" => %{
          "schema_version" => 1,
          "record_type" => "resource_scope_cancellation",
          "registration_id" => "registration",
          "scope_generation" => "scope-generation",
          "stop_generation" => "stop",
          "gate" => "sealed",
          "inventory_count" => 2,
          "slots" => slots,
          "inventory_digest" => Evidence.digest(slots),
          "local_cleanup" => "confirmed",
          "remote" => "unknown"
        },
        "executor_down" => true,
        "resources" => "confirmed",
        "local_cleanup" => "confirmed",
        "outcome" => "unknown"
      }
      |> Evidence.seal("retirement_digest")

    {operation, proof}
  end

  defp slot(index, terminal) do
    identity = %{
      "logical_id" => "logical-#{index}",
      "request_id" => "request-#{index}",
      "client_incarnation" => "client",
      "method" => "resources/list"
    }

    %{
      "index" => index,
      "identity" => identity,
      "phase" => "retired",
      "receipt" =>
        Map.merge(identity, %{
          "schema" => "resource_retirement",
          "version" => 1,
          "request_ids" => [identity["request_id"]],
          "terminal" => terminal,
          "local" => "retired",
          "local_cleanup" => "confirmed",
          "cleanup_evidence" => %{
            "workers_down" => true,
            "worker_count" => 1,
            "transport" => "confirmed"
          },
          "remote" => "unknown"
        })
    }
  end

  defp update_slot(proof, index, function),
    do: update_in(proof, ["cancellation", "slots"], &List.update_at(&1, index - 1, function))

  defp reseal(proof) do
    proof
    |> put_in(
      ["cancellation", "inventory_digest"],
      Evidence.digest(proof["cancellation"]["slots"])
    )
    |> Evidence.seal("retirement_digest")
  end
end
