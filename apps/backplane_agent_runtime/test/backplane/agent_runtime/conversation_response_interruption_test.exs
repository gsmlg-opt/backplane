defmodule Backplane.AgentRuntime.ConversationResponseInterruptionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  defmodule Provider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, context) do
      send(context.test, {:attempt, request, self(), context})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> send(context.test, {:retired, request.attempt_id}) end
      )
    end
  end

  defmodule Hooks do
    def prompt(message, context) do
      send(context.test, {:prompt, message})
      {:ok, message}
    end
  end

  test "interruption settles one attempt, discards unadmitted calls and consumes checkpointed input" do
    {pid, store} = start_conversation()

    audio = [%{type: :committed_audio, item_id: "item-a", connection_generation: 1}]
    assert {:ok, %{message_id: message_id}} = Conversation.prompt(pid, audio)
    assert_receive {:prompt, %{id: ^message_id, content: ^audio}}
    assert_receive {:attempt, first, worker, callbacks}
    assert [%{id: ^message_id, content: ^audio}] = first.messages

    assert {:ok, %{run: %{context: %{conversation: %{messages: [%{content: ^audio}]}}}}} =
             EphemeralStore.load(store, "voice")

    assert {:ok, %{message_id: next_id}} = Conversation.steer(pid, "next input")
    usage = %{input_tokens: 21, output_tokens: 4}
    pending = %{id: "unadmitted", name: "unused", arguments: %{}}

    interrupted = %{
      type: :response_interrupted,
      reason: "barge_in",
      message: %{role: :assistant, content: "partial"},
      usage: usage
    }

    send(
      worker,
      {:events,
       [%{type: :tool_call_completed, tool_call: pending}, interrupted, interrupted, done()]}
    )

    attempt_id = first.attempt_id
    assert_receive {:retired, ^attempt_id}

    assert_receive {:agent_runtime, "voice",
                    %{type: :response_interrupted, attempt_id: ^attempt_id, reason: "barge_in"}}

    assert_receive {:attempt, second, next_worker, _}
    assert second.attempt_id != attempt_id
    assert second.turn_id != first.turn_id
    assert Enum.map(second.messages, & &1.id) == [message_id, next_id]
    assert {:error, %Error{class: :resource_conflict}} = callbacks.emit.(interrupted)

    status = Conversation.status(pid)
    assert [%{outcome: :interrupted, reason: "barge_in"}] = status.conversation.turns
    assert [^usage] = status.conversation.usage

    assert %{status: :interrupted, terminal: %{message: %{content: "partial"}}} =
             status.run.last_provider_result

    assert status.run.active_tools == %{}
    refute_receive {:agent_runtime, "voice", %{type: :response_completed}}, 20
    send(next_worker, {:events, [done(), interrupted]})
    assert_receive {:agent_runtime, "voice", %{type: :run_completed}}
    refute_receive {:agent_runtime, "voice", %{type: :response_interrupted}}, 20
    assert Conversation.status(pid).run.last_provider_result.terminal.type == :response_completed
  end

  test "an interrupted response waits for explicit input without closing the run" do
    {pid, _store} = start_conversation()
    assert {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:attempt, first, worker, _}
    send(worker, {:events, [%{type: :response_interrupted, reason: "barge_in"}]})

    assert_receive {:agent_runtime, "voice", %{type: :response_interrupted}}

    assert %{phase: :awaiting_input, run: %{active_provider: nil, state: :running}} =
             Conversation.status(pid)

    refute_receive {:attempt, _, _, _}, 20
    assert {:ok, _} = Conversation.prompt(pid, "explicit next input")
    assert_receive {:attempt, second, worker, _}
    assert second.run_id == first.run_id
    assert second.turn_id != first.turn_id
    send(worker, {:events, [%{type: :response_failed, error: "provider failure"}, done()]})
    assert_receive {:agent_runtime, "voice", %{type: :run_failed}}
    refute_receive {:agent_runtime, "voice", %{type: :response_completed}}, 20
  end

  test "out-of-band response activity renews idle observation within a finite attempt deadline" do
    {pid, _store} = start_conversation(provider_idle_timeout: 400, provider_total_timeout: 700)
    assert {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:attempt, _, worker, _}
    monitor = Process.monitor(worker)

    for _ <- 1..4 do
      Process.sleep(100)
      send(worker, {:events, [%{type: :response_activity}]})
      assert_receive {:agent_runtime, "voice", %{type: :response_activity}}
    end

    Process.sleep(140)
    send(worker, {:events, [%{type: :response_activity}]})
    assert_receive {:agent_runtime, "voice", %{type: :response_activity}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 310
    assert_receive {:agent_runtime, "voice", %{type: :run_cancelled}}
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp start_conversation(overrides \\ []) do
    {:ok, store} = EphemeralStore.new(1)

    options = [
      run_id: "voice",
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      host_context: %{test: self()},
      hooks: Hooks,
      subscriber: self(),
      registry: %ToolRegistry{},
      authority: %{caller: "host", run_id: "voice", grants: []},
      run_timeout: 5_000,
      effect_timeout: 2_000
    ]

    {start_supervised!({Conversation, Keyword.merge(options, overrides)}), store}
  end
end
