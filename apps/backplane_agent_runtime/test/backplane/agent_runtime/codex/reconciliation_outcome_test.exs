Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationOutcomeTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  defmodule ProviderFailureError do
    defexception [:kind, :message, retryable: false]
  end

  defmodule OtherProviderFailureError do
    defexception [:kind, :message, retryable: false]
  end

  test "keeps canonical digests for all already-public outcome shapes" do
    for value <- [
          nil,
          true,
          1,
          1.5,
          :failed,
          "failed",
          [%{answer: "retained"}],
          Error.new(:timeout, "timeout")
        ] do
      assert Evidence.outcome_digest(value) == Evidence.digest(value)
    end
  end

  test "term-v1 preserves nested types, exception modules, and map ordering" do
    failure = %ProviderFailureError{kind: :server_error, message: "overloaded"}
    nested = %{error: failure, details: %{"key" => <<0, 255>>, key: {:failed, [1, 1.5]}}}
    reordered = Map.new(Enum.reverse(Map.to_list(nested)))
    digest = Evidence.outcome_digest(nested)

    assert "term-v1:" <> _ = digest
    assert Evidence.outcome_digest(reordered) == digest

    assert Evidence.outcome_digest(:erlang.binary_to_term(:erlang.term_to_binary(nested))) ==
             digest

    refute Evidence.outcome_digest(put_in(nested.details.key, ["failed", [1, 1.5]])) == digest

    refute Evidence.outcome_digest(%{
             nested
             | error: %OtherProviderFailureError{kind: failure.kind, message: failure.message}
           }) == digest
  end

  test "term-v1 uses a fixed canonical representation across fresh interpreters" do
    assert Evidence.outcome_digest({:failed, %{"x" => [1, 1.5, <<0, 255>>]}}) ==
             "term-v1:122ccba582f448d6b4f9ce156523ea995f52d0cd2077930f5d50865f9843cbf6"
  end

  test "stored term-v1 prefixes retain their algorithm after public normalization accepts a value" do
    public = %{outcome: :failed, message: "overloaded"}
    versioned = Evidence.outcome_digest(public, "term-v1:previous-receipt")

    assert "term-v1:" <> _ = versioned
    refute versioned == Evidence.outcome_digest(public)
    assert Evidence.outcome_digest(public, versioned) == versioned

    {host, _original, manifest, request} = failed_child(public)
    assert {:ok, receipt} = Reconciliation.reconcile(Host.config(host), request)
    [historical] = receipt["historical_outcomes"]

    stored =
      receipt
      |> Map.put("historical_outcomes", [Map.put(historical, "outcome_digest", versioned)])
      |> Evidence.seal("receipt_digest")

    :ok = Host.put(host, {:receipt, request["receipt_id"]}, stored)

    assert {:ok, ^stored} =
             Reconciliation.load_confirmed(
               Host.config(host),
               request["receipt_id"],
               manifest["subject"],
               manifest["manifest_digest"]
             )
  end

  test "retains existing canonical digests and authority checks for public outcomes" do
    outcome = %{error: %{kind: :server_error, message: "overloaded"}, outcome: :failed}
    {host, original, manifest, request} = failed_child(outcome)

    assert {:ok, receipt} = Reconciliation.reconcile(Host.config(host), request)

    assert receipt["historical_outcomes"] == [
             %{
               "run_id" => "child-run",
               "state" => "failed",
               "outcome_digest" => Evidence.digest(outcome)
             }
           ]

    assert {:ok, ^receipt} =
             Reconciliation.load_confirmed(
               Host.config(host),
               request["receipt_id"],
               manifest["subject"],
               manifest["manifest_digest"]
             )

    assert {:ok, ^original} = EphemeralStore.load(host.store, "child-run")
  end

  test "confirms failed historical outcomes without rewriting foreign error structs" do
    outcome = %{
      error: %ProviderFailureError{
        kind: :server_error,
        message: "Our servers are currently overloaded. Please try again later."
      },
      outcome: :failed,
      turn_id: "provider-turn"
    }

    {host, original, manifest, request} = failed_child(outcome)
    original_bytes = :erlang.term_to_binary(original)

    assert {:ok, %{"retirement" => "confirmed"} = receipt} =
             Reconciliation.reconcile(Host.config(host), request)

    assert receipt["historical_outcomes"] == [
             %{
               "run_id" => "child-run",
               "state" => "failed",
               "outcome_digest" => Evidence.outcome_digest(outcome)
             }
           ]

    assert {:ok, ^receipt} = Reconciliation.reconcile(Host.config(host), request)

    assert {:ok, ^receipt} =
             Reconciliation.load_confirmed(
               Host.config(host),
               request["receipt_id"],
               manifest["subject"],
               manifest["manifest_digest"]
             )

    assert {:ok, ^original} = EphemeralStore.load(host.store, "child-run")
    assert :erlang.term_to_binary(original) == original_bytes
    assert {:ok, _} = Evidence.public(receipt)
    assert {:error, %Error{class: :validation}} = Evidence.public(outcome)
  end

  test "retains uncertainty when failed history has an unobserved lifetime obligation" do
    outcome = %{error: %ProviderFailureError{kind: :server_error, message: "overloaded"}}
    {host, original, _manifest, request} = failed_child(outcome, false)

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(host), request)

    assert {:ok, %{"closure" => "pending", "retirement" => "pending"}} =
             Host.load_receipt(host, request["receipt_id"])

    assert {:ok, ^original} = EphemeralStore.load(host.store, "child-run")
  end

  test "unrepresentable or oversized historical outcomes cannot create retirement receipts" do
    failure = %ProviderFailureError{kind: :server_error, message: "overloaded"}

    for value <- [
          self(),
          Enum.reduce(1..33, failure, fn _, nested -> [nested] end),
          List.duplicate(nil, 262_144),
          String.duplicate("x", 16_777_217)
        ] do
      {host, original, _manifest, request} = failed_child(%{error: failure, value: value})

      assert {:error, %Error{class: :unknown_outcome}} =
               Reconciliation.reconcile(Host.config(host), request)

      assert {:error, %Error{class: :not_found}} =
               Host.load_receipt(host, request["receipt_id"])

      assert {:ok, ^original} = EphemeralStore.load(host.store, "child-run")
    end
  end

  defp failed_child(outcome, observed? \\ true) do
    host = Host.new()

    queued = %{
      run_id: "child-run",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: :infinity,
      outcome: nil,
      children: [],
      execution_budget: %{quota: 10, used: 1},
      context: %{}
    }

    {:ok, _} =
      EphemeralStore.store(host.store, queued, %{command: {:admit, 1, %{state: :running}}})

    {:ok, %{run: run}} = EphemeralStore.load(host.store, queued.run_id)

    {:ok, _} =
      EphemeralStore.store(host.store, run, %{
        command:
          {:finish, 2, %{run_id: run.run_id, incarnation: 1, status: :failed, outcome: outcome}}
      })

    {:ok, original} = EphemeralStore.load(host.store, queued.run_id)

    obligation =
      Evidence.obligation(
        "executor",
        %{"run_id" => queued.run_id, "incarnation" => 1},
        "admission:1"
      )

    manifest =
      Host.manifest(
        Host.subject(),
        [%{"store_ref" => queued.run_id, "run_id" => queued.run_id, "original_incarnation" => 1}],
        [obligation]
      )

    observations = if observed?, do: [Host.observe(obligation)], else: []
    :ok = Host.put(host, {:evidence, "evidence"}, Host.bundle(manifest, observations))
    {host, original, manifest, Host.request(manifest)}
  end
end
