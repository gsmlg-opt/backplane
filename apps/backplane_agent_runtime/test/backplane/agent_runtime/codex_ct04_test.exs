defmodule Backplane.AgentRuntime.CodexCT04Test do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.{ContextTools, Interactions, Permissions, Readiness}

  @auth %{run_id: "run-1", token: "token-1", owner: "owner-1", incarnation: 2}

  test "input variants acknowledge once and reject duplicate, stale, and cross-run answers" do
    state = Interactions.new()

    assert {:ok, state,
            %{
              kind: :request,
              status: :requested,
              acknowledgement: :accepted,
              completion: :pending
            } = receipt} =
             Interactions.request(state, :request, "question", @auth)

    id = receipt.interaction_id

    assert {:error, %{class: :forbidden}} =
             Interactions.answer(state, id, "cross-run", %{@auth | run_id: "run-2"})

    assert {:ok, state, %{status: :answered, completion: :settled}} =
             Interactions.answer(state, id, "answer", @auth)

    assert {:error, %{class: :not_found}} = Interactions.answer(state, id, "again", @auth)

    assert {:ok, state, %{kind: :cancel, status: :cancel_requested} = receipt2} =
             Interactions.request(state, :cancel, %{reason: :user}, @auth)

    assert {:ok, _state, %{status: :cancelled}} =
             Interactions.cancel(state, receipt2.interaction_id, @auth)
  end

  test "permission denial creates no capability or side effect" do
    {:ok, request} =
      Permissions.request_permissions(%{capability: "fs.write", scope: %{path: "/tmp/a"}}, @auth)

    decision_request = request.decision_request

    self_resolver =
      Map.merge(@auth, Map.take(decision_request, [:permission_id, :run_id, :owner]))

    assert {:error, %{class: :forbidden}} =
             Permissions.decide(decision_request, :allow, self_resolver)

    resolver = %{
      run_id: decision_request.run_id,
      permission_id: decision_request.permission_id,
      owner: "host-operator",
      resolver_id: "host-operator",
      host_authorized: true
    }

    assert {:ok, %{status: :denied, capability: nil, side_effects: :none}} =
             Permissions.decide(decision_request, :deny, resolver)

    assert {:ok, %{status: :granted, grant: %{scope: %{path: "/tmp/a"}}}} =
             Permissions.decide(decision_request, :allow, resolver)
  end

  test "readiness refuses execution and supports timeout and cancellation" do
    refute Readiness.ready?(%{ready: true, authorized: false})

    assert {:error, %{class: :forbidden}} =
             Readiness.execute_if_ready(%{ready: false, authorized: true}, fn ->
               send(self(), :ran)
             end)

    refute_received :ran

    assert {:error, %{class: :timeout}} =
             Readiness.await(fn -> %{ready: false, authorized: false} end, 1)

    assert {:error, %{class: :cancelled}} =
             Readiness.await(fn -> %{ready: false, authorized: false} end, 100, fn -> true end)

    assert {:ok, %{ready: true, authorized: true}} =
             Readiness.await(fn -> %{ready: true, authorized: true} end, 10)
  end

  test "context replacement preserves run, environment, resources and provenance" do
    context = %{
      run_id: "run-1",
      environment: %{cwd: "/tmp"},
      resources: ["cmd-1"],
      authority: %{grant: "g"},
      revision: 4,
      history: []
    }

    assert {:ok, replacement} =
             ContextTools.new_context(context, %{
               messages: [%{id: "m2"}],
               provenance: %{source: :compaction}
             })

    assert replacement.run_id == context.run_id
    assert replacement.environment == context.environment
    assert replacement.resources == context.resources
    assert replacement.authority == context.authority
    assert replacement.revision == 5
    assert [%{type: :context_replaced, provenance: %{source: :compaction}}] = replacement.history

    assert {:ok, %{availability: :unavailable, capacity: :unknown}} =
             ContextTools.get_context_remaining(replacement)
  end
end
