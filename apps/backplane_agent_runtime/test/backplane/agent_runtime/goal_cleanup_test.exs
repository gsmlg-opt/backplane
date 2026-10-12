Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalCleanupTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Goal, GoalFileStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session

  @moduletag :tmp_dir

  defmodule Host do
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  defmodule Provider do
    def stream(_request, context) do
      send(context.test, {:provider, self()})

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

  defmodule GoalProxy do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call({:unbind, binding}, from, state) do
      token = make_ref()
      send(state.test, {:goal_unbind_waiting, self(), token})
      {:noreply, Map.put(state, :pending, {from, binding, token})}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.goal, request), state}

    def handle_info({:release_unbind, token}, %{pending: {from, binding, token}} = state) do
      GenServer.reply(from, Goal.unbind(state.goal, binding))
      {:noreply, Map.delete(state, :pending)}
    end

    def handle_info(_, state), do: {:noreply, state}
  end

  setup ctx do
    store = start_supervised!({GoalFileStore, ctx.tmp_dir})
    session = start_supervised!({Session, owner_pid: self()})

    goal =
      start_supervised!(
        {Goal,
         thread_id: "cleanup-thread",
         owner_pid: self(),
         store: GoalFileStore,
         store_context: store,
         host: Host,
         host_context: nil}
      )

    {:ok, _} = Goal.set(goal, %{objective: "ship"}, %{text: "ship"})

    proxy =
      start_supervised!(%{
        id: GoalProxy,
        start: {GoalProxy, :start_link, [[goal: goal, test: self()]]},
        restart: :temporary
      })

    %{goal: goal, proxy: proxy, session: session}
  end

  defp complete_until_unbind(ctx, opts \\ []) do
    run_id = "cleanup-run"
    authority = %{caller: "host", run_id: run_id, grants: []}
    {:ok, session_binding} = Session.bind(ctx.session, authority)

    {:ok, goal_binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "cleanup-thread",
        run_id: run_id,
        incarnation: 1,
        authority: authority,
        usage_authoritative: true
      })

    {:ok, table} = EphemeralStore.new(1)

    options =
      Keyword.merge(
        [
          run_id: run_id,
          store: EphemeralStore,
          context: table,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: %ToolRegistry{},
          tools: [],
          authority: authority,
          session_binding: session_binding,
          goal: ctx.proxy,
          goal_binding: goal_binding,
          thread_id: "cleanup-thread",
          run_timeout: :infinity
        ],
        opts
      )

    pid =
      start_supervised!(%{
        id: Conversation,
        start: {Conversation, :start_link, [options]},
        restart: :temporary
      })

    {:ok, _} = Conversation.prompt(pid, "work")
    assert_receive {:provider, worker}, 1_000

    send(
      worker,
      {:events,
       [
         %{
           type: :response_completed,
           message: %{role: :assistant, content: "done"},
           usage: %{input_tokens: 10, cached_tokens: 0, output_tokens: 2}
         }
       ]}
    )

    assert_receive {:goal_unbind_waiting, proxy, token}, 1_000
    on_exit(fn -> send(proxy, {:release_unbind, token}) end)
    {pid, proxy, token}
  end

  test "Conversation owner stays responsive while Goal revocation is pending", ctx do
    {pid, proxy, token} = complete_until_unbind(ctx)
    query = Task.async(fn -> Conversation.status(pid) end)
    response = Task.yield(query, 200) || Task.shutdown(query, :brutal_kill)
    assert {:ok, %{run: _}} = response
    refute_receive {:agent_runtime, "cleanup-run", %{type: :run_completed}}, 10
    send(proxy, {:release_unbind, token})
    assert_receive {:agent_runtime, "cleanup-run", %{type: :run_completed}}, 1_000
  end

  test "Goal revocation timeout reports controlled storage failure within its configured bound",
       ctx do
    {pid, _, _} = complete_until_unbind(ctx, commit_timeout: 50, cleanup_timeout: 50)

    assert_receive {:agent_runtime, "cleanup-run",
                    %{type: :storage_failed, recovery_required: true}},
                   300

    assert Process.alive?(pid)
    assert Conversation.status(pid).phase == :storage_failed
    refute_receive {:agent_runtime, "cleanup-run", %{type: :run_completed}}, 10
  end

  test "Goal owner death before revocation acknowledgement reports controlled failure", ctx do
    {pid, proxy, _} = complete_until_unbind(ctx)
    monitor = Process.monitor(pid)
    Process.exit(proxy, :kill)

    assert_receive {:agent_runtime, "cleanup-run",
                    %{type: :storage_failed, recovery_required: true}},
                   300

    assert Process.alive?(pid)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _}, 10
    assert Conversation.status(pid).phase == :storage_failed
  end
end
