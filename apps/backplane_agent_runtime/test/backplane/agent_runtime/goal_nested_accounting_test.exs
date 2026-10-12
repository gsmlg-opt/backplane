Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalNestedAccountingTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Goal, GoalFileStore}
  alias Backplane.AgentRuntime.Codex.{ExtensionRuntime, Session}
  @moduletag :tmp_dir

  defmodule Host do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

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

  defmodule Steps do
    def execute(operation) do
      ctx = operation.backend_context

      case operation.tool_name do
        "step::read" ->
          send(ctx.test, :nested_read)

        "step::write" ->
          File.write!(ctx.marker, "mutated")
          send(ctx.test, :nested_mutation)
      end

      {:ok, %{text: "done"}}
    end
  end

  defmodule GatedStore do
    def load(ctx, thread), do: GoalFileStore.load(ctx.store, thread)

    def compare_and_swap(ctx, thread, revision, goal_id, next) do
      if Agent.get(ctx.gate, & &1) and Enum.any?(next.turns, fn {_, turn} -> turn.success end) do
        send(ctx.test, {:nested_goal_ack_waiting, self()})

        receive do
          :allow ->
            Agent.update(ctx.gate, fn _ -> false end)
            GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
        end
      else
        GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
      end
    end
  end

  setup ctx do
    assert is_binary(System.find_executable("deno")), "Deno 2.8.3 is required"
    store = start_supervised!({GoalFileStore, ctx.tmp_dir})
    session = start_supervised!({Session, owner_pid: self()})
    gate = start_supervised!({Agent, fn -> true end})

    {adapter, storage} =
      if ctx[:gated],
        do: {GatedStore, %{store: store, gate: gate, test: self()}},
        else: {GoalFileStore, store}

    goal =
      start_supervised!(
        {Goal,
         thread_id: "nested-thread",
         owner_pid: self(),
         store: adapter,
         store_context: storage,
         host: Host,
         host_context: nil}
      )

    %{goal: goal, session: session, marker: Path.join(ctx.tmp_dir, "mutation")}
  end

  defp start_run(ctx, run_id) do
    names = ["exec", "wait", "create_goal", "update_goal", "step::read", "step::write"]

    authority = %{
      caller: "host",
      run_id: run_id,
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    {:ok, session_binding} = Session.bind(ctx.session, authority)

    runtime =
      start_supervised!(
        {ExtensionRuntime,
         goal: ctx.goal,
         scope: %{host_id: "h", caller_id: "host", run_id: run_id, project_id: "p"}}
      )

    steps =
      for name <- ["read", "write"] do
        %{
          namespace: "step",
          name: name,
          description: "Test #{name}",
          schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
          backend: Steps,
          backend_context: %{test: self(), marker: ctx.marker},
          revision: 1,
          safety: %{read_only: name == "read", retry_safe: name == "read", parallel_safe: false}
        }
      end

    goals =
      ExtensionRuntime.contracts(%{extension_runtime: runtime})
      |> Enum.filter(&(&1.name in ["create_goal", "update_goal"]))

    {:ok, profile} =
      Codex.profile(
        :code_mode_only,
        %{
          session_binding: session_binding,
          resource_registry: session_binding.resource_registry,
          code_mode_contracts: goals ++ steps
        },
        authority
      )

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "nested-thread",
        run_id: run_id,
        incarnation: 1,
        authority: authority,
        usage_authoritative: true
      })

    {:ok, table} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         store: EphemeralStore,
         context: table,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: session_binding,
         goal: ctx.goal,
         goal_binding: binding,
         thread_id: "nested-thread",
         run_timeout: :infinity,
         effect_timeout: 5_000,
         cleanup_timeout: 3_000,
         work: 20}
      )

    {:ok, _} = Conversation.prompt(pid, "run code")
    assert_receive {:provider, _, worker}, 1_000
    {pid, worker}
  end

  defp execute(worker, source) do
    send(
      worker,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "exec-call", name: "exec", arguments: source}
         },
         %{
           type: :response_completed,
           message: %{role: :assistant, content: "running"},
           usage: %{input_tokens: 10, cached_tokens: 0, output_tokens: 1}
         }
       ]}
    )
  end

  test "CodeMode can create then update the new goal within the same execution", ctx do
    {_, worker} = start_run(ctx, "nested-create")

    execute(
      worker,
      "await codex.tool('create_goal', {objective:'ship'}); return await codex.tool('update_goal', {status:'complete'});"
    )

    assert_receive {:provider, _, _}, 5_000
    assert {:ok, %{goal: %{status: :complete}}} = Goal.get(ctx.goal)
  end

  @tag gated: true
  test "nested accounting acknowledgement precedes admission of the next side effect", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 100}, %{text: "ship"})
    {_, worker} = start_run(ctx, "nested-gate")

    execute(
      worker,
      "await codex.tool('step::read', {}); await codex.tool('step::write', {}); return 'done';"
    )

    assert_receive :nested_read, 5_000
    assert_receive {:nested_goal_ack_waiting, waiter}, 5_000
    refute File.exists?(ctx.marker)
    refute_receive :nested_mutation, 20
    send(waiter, :allow)
    assert_receive :nested_mutation, 5_000
    assert_receive {:provider, _, _}, 5_000
  end
end
