Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ProviderLossContinuationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error, Store, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Continuation, Evidence}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:provider, request})
      [%{type: :response_completed, message: %{role: :assistant, content: "Fresh answer"}}]
    end
  end

  setup %{tmp_dir: path} do
    {:ok, host} = Host.open(path)
    on_exit(fn -> Host.cleanup(host) end)
    original = seed_running_source(host)

    request = %{
      "schema_version" => 1,
      "mode" => "isolated_provider_loss",
      "subject" => %{
        "kind" => "session",
        "scope_id" => "thread",
        "owner_id" => "lost-session",
        "incarnation" => 42
      },
      "source" => %{
        "run_id" => "source",
        "original_incarnation" => 1,
        "store_ref" => "source-store"
      },
      "root_agent_id" => "root-agent",
      "instruction_ref" => "new-instruction",
      "evidence_ref" => "original-generation-fence"
    }

    {:ok, provider} = Evidence.public(original.run.active_provider)

    isolation =
      request
      |> Map.take(~w(schema_version subject source root_agent_id))
      |> Map.merge(%{
        "source_revision" => original.revision,
        "provider" => provider,
        "root_admission_ref" => "thread-admission-ledger",
        "runtime_fence_ref" => "permanent-generation-fence",
        "effect_isolation_ref" => "generation-scoped-effect-domain"
      })

    %{host: host, path: path, original: original, request: request, isolation: isolation}
  end

  test "cold attach reserves a single fresh run and leaves the previous request unknown", ctx do
    assert :ok = Host.put(ctx.host, {:excluded_run, "source"}, true)
    assert :ok = put_isolation(ctx, ctx.isolation)
    assert :ok = Host.cleanup(ctx.host)
    assert {:ok, host} = Host.open(ctx.path)
    on_exit(fn -> Host.cleanup(host) end)
    config = Host.config(host)

    assert {:ok, original} = Host.load(host, "source")
    assert original == ctx.original
    assert original.run.state == :running
    assert map_size(original.run.provider_attempts) == 36
    assert map_size(original.run.tool_results) == 38
    assert original.run.active_tools == %{}

    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> Continuation.prepare(config, ctx.request) end) end)
      |> Task.await_many()

    assert [{:ok, decision}] = Enum.uniq(results)
    assert %{"state" => "running", "certainty" => "unknown"} = decision["historical_outcome"]
    assert %{"identity" => identity, "outcome" => "unknown"} = decision["unresolved_provider"]
    assert identity == ctx.isolation["provider"]
    assert decision["source_revision"] == original.revision
    assert decision["unresolved_tools"] == []
    assert decision["historical_limits"]["provider_stop"] == "unconfirmed"
    assert decision["historical_limits"]["native_retirement"] == "unconfirmed"
    refute Map.has_key?(decision, "receipt_id")

    assert {:error, %Error{class: :resource_conflict}} =
             Continuation.prepare(config, %{ctx.request | "instruction_ref" => "different"})

    assert {:error, %Error{class: :resource_conflict}} =
             Store.store(Host, host, original.run, %{command: {:cancel, original.revision + 1}})

    assert {:error, %Error{class: :resource_conflict}} =
             Store.fence(Host, host, "source", original.revision, 1, 2)

    fresh = decision["target"]["run_id"]
    notice = decision["model_notice"]
    prior = original.run.context.conversation.messages

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: config, recovery_scope_id: "thread"}
      )

    authority = %{caller: "host", run_id: fresh, grants: []}
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    opts = [
      run_id: fresh,
      incarnation: 1,
      session_binding: binding,
      store: Host,
      context: host,
      authority: authority,
      registry: %ToolRegistry{},
      tools: [],
      provider: Provider,
      provider_context: %{test: self()},
      subscriber: self(),
      messages: prior ++ [%{role: :user, content: notice}]
    ]

    conversation = start_supervised!({Conversation, opts})
    assert {:ok, _} = Conversation.prompt(conversation, "Explicit next instruction")

    assert_receive {:provider, %{run_id: ^fresh, messages: messages}}, 2_000

    assert Enum.map(messages, &Map.take(&1, [:role, :content])) ==
             prior ++
               [
                 %{role: :user, content: notice},
                 %{role: :user, content: "Explicit next instruction"}
               ]

    assert_receive {:agent_runtime, ^fresh, %{type: :run_completed}}, 2_000

    duplicate =
      start_supervised!(
        Supervisor.child_spec({Conversation, Keyword.delete(opts, :session_binding)},
          id: :duplicate_continuation
        )
      )

    assert {:error, %Error{class: :resource_conflict}} =
             Conversation.prompt(duplicate, "Explicit next instruction")

    refute_receive {:provider, _}
    assert {:ok, ^original} = Host.load(host, "source")
    assert original.run.context.goal_attribution.goal_id == "prior-goal"

    assert :ok = Host.cleanup(host)
    assert {:ok, reopened} = Host.open(ctx.path)
    on_exit(fn -> Host.cleanup(reopened) end)
    assert {:ok, ^decision} = Continuation.prepare(Host.config(reopened), ctx.request)
    assert {:ok, ^original} = Host.load(reopened, "source")
    assert {:ok, %{run: %{state: :completed}}} = Host.load(reopened, fresh)
  end

  test "missing, incomplete, foreign and stale isolation cannot admit a new run", ctx do
    assert {:error, %Error{class: :unknown_outcome}} =
             Continuation.prepare(Host.config(ctx.host), ctx.request)

    assert :ok = put_isolation(ctx, ctx.isolation)

    assert {:error, %Error{class: :unknown_outcome}} =
             Continuation.prepare(Host.config(ctx.host), ctx.request)

    assert :ok = Host.put(ctx.host, {:excluded_run, "source"}, true)

    for {ref, evidence, class} <- [
          {"missing-effects", Map.delete(ctx.isolation, "effect_isolation_ref"), :validation},
          {"same-proof",
           %{ctx.isolation | "effect_isolation_ref" => "permanent-generation-fence"},
           :validation},
          {"other-session", put_in(ctx.isolation, ["subject", "owner_id"], "other"),
           :resource_conflict},
          {"stale", %{ctx.isolation | "source_revision" => ctx.original.revision - 1},
           :resource_conflict},
          {"other-provider", put_in(ctx.isolation, ["provider", "attempt_id"], "other"),
           :resource_conflict}
        ] do
      request = %{ctx.request | "evidence_ref" => ref}
      assert :ok = put_isolation(%{ctx | request: request}, evidence)

      assert {:error, %Error{class: ^class}} =
               Continuation.prepare(Host.config(ctx.host), request)
    end

    assert {:ok, ctx.original} == Host.load(ctx.host, "source")
  end

  test "incomplete or contradictory Runtime inventories cannot establish isolation", ctx do
    foreign = %{
      "tool:tool-1" => %{
        type: :tool,
        status: :consumed,
        operation: %{run_id: "other-run", incarnation: 1, invocation_id: "tool-1"}
      }
    }

    for {name, run} <- [
          {"missing-tools", Map.delete(ctx.original.run, :active_tools)},
          {"missing-results", Map.delete(ctx.original.run, :tool_results)},
          {"foreign-intent", Map.put(ctx.original.run, :execution_intents, foreign)}
        ] do
      {:ok, host} = Host.open(Path.join(ctx.path, name))
      on_exit(fn -> Host.cleanup(host) end)
      assert :ok = Host.put(host, {:run, "source"}, %{ctx.original | run: run})
      assert :ok = put_isolation(%{ctx | host: host}, ctx.isolation)
      assert :ok = Host.put(host, {:excluded_run, "source"}, true)

      assert {:error, %Error{class: :unknown_outcome}} =
               Continuation.prepare(Host.config(host), ctx.request)
    end
  end

  test "a stored decision still requires verified isolation on cold readback", ctx do
    assert :ok = Host.put(ctx.host, {:excluded_run, "source"}, true)
    assert :ok = put_isolation(ctx, ctx.isolation)
    assert :ok = Host.fault_next(ctx.host, :continuation, :lose_ack)
    assert {:ok, decision} = Continuation.prepare(Host.config(ctx.host), ctx.request)

    {:ok, copied} = Host.open(Path.join(ctx.path, "without-isolation"))
    on_exit(fn -> Host.cleanup(copied) end)
    assert :ok = Host.put(copied, {:run, "source"}, ctx.original)
    assert :ok = Host.put(copied, {:continuation, decision["continuation_id"]}, decision)
    assert :ok = put_isolation(%{ctx | host: copied}, ctx.isolation)

    assert {:error, %Error{class: :unknown_outcome}} =
             Continuation.prepare(Host.config(copied), ctx.request)

    assert :ok = Host.put(copied, {:excluded_run, "source"}, true)
    assert {:ok, ^decision} = Continuation.prepare(Host.config(copied), ctx.request)
  end

  defp put_isolation(ctx, evidence) do
    Host.put(ctx.host, {:provider_loss_isolation, ctx.request["evidence_ref"]}, evidence)
  end

  defp seed_running_source(host) do
    source = %{
      run_id: "source",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      children: [],
      context: %{
        conversation: %{
          messages: [%{role: :user, content: "Earlier instruction"}],
          goal_outbox: []
        },
        goal_attribution: %{goal_id: "prior-goal", run_id: "source", incarnation: 1}
      }
    }

    run = commit(host, source, :admit, %{state: :running})

    run =
      Enum.reduce(1..35, run, fn index, run ->
        attempt = provider_identity(index)
        started = commit(host, run, :provider_started, attempt)

        commit(
          host,
          started,
          :provider_completed,
          Map.merge(attempt, %{result: %{}, final?: false})
        )
      end)

    run =
      Enum.reduce(1..38, run, fn index, run ->
        call =
          Map.merge(provider_identity(35), %{
            invocation_id: "tool-#{index}",
            tool_name: "read_file",
            tool_revision: 1,
            arguments: %{}
          })

        result = %{content: "Settled result #{index}"}
        started = commit(host, run, :tool_invoked, call)
        commit(host, started, :tool_completed, Map.put(call, :result, result))
      end)

    _run = commit(host, run, :provider_started, provider_identity(36))
    assert {:ok, record} = Host.load(host, "source")
    record
  end

  defp provider_identity(index),
    do: %{run_id: "source", incarnation: 1, step_id: "step-#{index}", attempt_id: "try-#{index}"}

  defp commit(host, run, kind, input) do
    command = {kind, run.expected_revision + 1, input}
    assert {:ok, _} = Store.store(Host, host, run, %{command: command})
    assert {:ok, %{run: next}} = Host.load(host, "source")
    next
  end
end
