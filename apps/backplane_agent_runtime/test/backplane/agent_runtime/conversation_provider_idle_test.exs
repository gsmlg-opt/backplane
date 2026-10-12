defmodule Backplane.AgentRuntime.ConversationProviderIdleTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}

  defmodule Provider do
    def stream(_, context) do
      send(context.test, {:provider, self(), context})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} ->
              {events, state}

            :ask ->
              answer = context.interact.(%{kind: :permission})
              send(context.test, {:answer, answer})
              {[], state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start(opts) do
    {:ok, store} = EphemeralStore.new(1)

    opts =
      Keyword.merge(
        [
          run_id: "idle",
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: %ToolRegistry{},
          authority: %{caller: "host", run_id: "idle", grants: []},
          run_timeout: :infinity,
          effect_timeout: 70,
          provider_idle_timeout: 50
        ],
        opts
      )

    pid = start_supervised!({Conversation, opts}, id: Conversation)
    assert {:ok, _} = Conversation.prompt(pid, "work")
    assert_receive {:provider, worker, context}
    {pid, worker, context}
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  test "validated provider progress renews idle observation beyond total effect timeout" do
    {pid, worker, _} = start([])

    for _ <- 1..6 do
      Process.sleep(20)
      send(worker, {:events, [%{type: :content_text_delta, delta: "x"}]})
      assert_receive {:agent_runtime, "idle", %{type: :content_text_delta}}
    end

    send(worker, {:events, [done()]})
    assert_receive {:agent_runtime, "idle", %{type: :run_completed}}
    assert Conversation.status(pid).run.state == :completed
  end

  test "omitted idle option preserves total provider effect timeout" do
    {_, worker, _} = start(provider_idle_timeout: nil)

    for _ <- 1..2 do
      Process.sleep(20)
      send(worker, {:events, [%{type: :content_text_delta, delta: "x"}]})
      assert_receive {:agent_runtime, "idle", %{type: :content_text_delta}}
    end

    assert_receive {:agent_runtime, "idle", %{type: :run_cancelled}}, 500
  end

  test "first event and later stalls remain bounded with infinite run" do
    {_, _, _} = start([])
    assert_receive {:agent_runtime, "idle", %{type: :run_cancelled}}, 500
  end

  test "stale timeout generations and tool metadata do not renew provider observation" do
    {pid, worker, context} = start([])
    prior = :sys.get_state(pid).effect
    send(worker, {:events, [%{type: :content_text_delta, delta: "x"}]})
    assert_receive {:agent_runtime, "idle", %{type: :content_text_delta}}
    current = :sys.get_state(pid).effect
    refute prior.timer_generation == current.timer_generation
    send(pid, {:timeout, prior.task.ref, prior.timer_generation})
    assert :ok = context.emit.(%{progress: 1})
    assert :sys.get_state(pid).effect.timer_generation == current.timer_generation

    assert {:error, _} =
             GenServer.call(
               pid,
               {:provider_chunk, make_ref(), %{type: :content_text_delta, delta: "stale"}}
             )

    assert :sys.get_state(pid).effect.timer_generation == current.timer_generation
    send(worker, {:events, [done()]})
    assert_receive {:agent_runtime, "idle", %{type: :run_completed}}
  end

  test "human interaction pauses idle and infinite root timers" do
    {pid, worker, _} = start([])
    prior = :sys.get_state(pid).effect
    send(worker, :ask)
    assert_receive {:agent_runtime, "idle", %{type: :interaction_requested, interaction_id: id}}
    paused = :sys.get_state(pid)
    assert paused.paused_run_remaining == :infinity
    assert paused.effect.timer == nil
    Process.sleep(80)
    assert Conversation.status(pid).phase == :waiting_interaction
    assert :ok = Conversation.resolve(pid, id, :allow)
    assert_receive {:answer, {:ok, :allow}}
    assert :sys.get_state(pid).run.deadline == :infinity
    assert :sys.get_state(pid).timer == nil
    resumed = :sys.get_state(pid).effect
    refute prior.timer_generation == resumed.timer_generation
    send(pid, {:timeout, prior.task.ref, prior.timer_generation})
    send(worker, {:events, [done()]})
    assert_receive {:agent_runtime, "idle", %{type: :run_completed}}
  end

  test "invalid provider callbacks and output overflow do not renew idle timers" do
    {pid, worker, context} = start(provider_output_limit: 1)
    current = :sys.get_state(pid).effect
    assert {:error, _} = context.provider_emit.(%{progress: 1})
    assert {:error, _} = context.provider_emit.(%{type: :usage_updated, usage: :bad})

    assert {:error, _} =
             context.provider_emit.(%{type: :usage_updated, usage: %{input_tokens: -1}})

    assert :sys.get_state(pid).effect.timer_generation == current.timer_generation
    send(worker, {:events, [%{type: :content_text_delta, delta: "oversized"}]})
    assert_receive {:agent_runtime, "idle", %{type: :run_failed}}
    refute_receive {:agent_runtime, "idle", %{type: :content_text_delta}}, 20
  end

  test "malformed duplicate and unsupported provider events fail without dispatch or retry" do
    for events <- [
          [%{type: :tool_call_completed}],
          [%{type: :unknown_event}],
          [%{type: :content_text_delta, delta: 42}],
          List.duplicate(
            %{
              type: :tool_call_completed,
              tool_call: %{id: "same", name: "missing", arguments: %{}}
            },
            2
          )
        ] do
      {pid, worker, _} = start([])
      send(worker, {:events, events})
      assert_receive {:agent_runtime, "idle", %{type: :run_failed}}
      assert Conversation.status(pid).run.state == :failed
      refute_receive {:provider, _, _}, 20
      stop_supervised!(Conversation)
    end
  end

  test "cancel during provider interaction fences late progress" do
    {pid, worker, context} = start([])
    send(worker, :ask)
    assert_receive {:agent_runtime, "idle", %{type: :interaction_requested}}
    monitor = Process.monitor(worker)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_receive {:agent_runtime, "idle", %{type: :run_cancelled}}
    assert {:error, _} = context.provider_emit.(%{type: :content_text_delta, delta: "late"})
  end

  test "finite root expires despite provider progress" do
    {_, worker, _} = start(run_timeout: 80, effect_timeout: 500)

    for _ <- 1..2 do
      Process.sleep(20)
      send(worker, {:events, [%{type: :content_text_delta, delta: "x"}]})
      assert_receive {:agent_runtime, "idle", %{type: :content_text_delta}}
    end

    assert_receive {:agent_runtime, "idle", %{type: :run_cancelled}}, 500
  end
end
