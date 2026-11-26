defmodule Backplane.AgentRuntime.ConversationProviderRetryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state -> receive do: ({:events, events} -> {events, state}) end,
        fn _ ->
          send(context.test, {:provider_retiring, self()})
          if context[:hold_retirement], do: receive(do: (:retire -> :ok))
        end
      )
    end
  end

  defmodule Hooks do
    def prepare_provider_retry(snapshot, context) do
      send(context.test, {:retry_boundary, snapshot, self()})

      receive do
        :ack -> :ok
        :reject -> {:error, Error.new(:execution_failure, "Writer did not acknowledge")}
      end
    end
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :provider_completed and
           Map.has_key?(elem(meta.command, 2).result, :error) do
        send(context.test, {:failure_store, self()})

        receive do
          :ack -> EphemeralStore.store(context.table, run, meta)
          :reject -> {:error, Error.new(:execution_failure, "Store did not acknowledge")}
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool, operation.tool_call_id})
      {:ok, %{text: "settled"}}
    end
  end

  test "partial failed attempt is committed once and replacement has fresh identity" do
    {pid, table} = start()
    {first, provider} = prompt(pid)
    observed = %{input_tokens: 7, output_tokens: 2}

    send(
      provider,
      {:events, [%{type: :usage_updated, usage: observed}, failure(:stream, "partial", observed)]}
    )

    {second, provider} = replacement()
    refute second.attempt_id == first.attempt_id
    assert second.turn_id == first.turn_id
    assert List.last(second.messages) == %{role: :assistant, content: "partial"}
    status = Conversation.status(pid)
    assert status.conversation.usage == [observed]
    assert [record] = status.conversation.provider_failures
    assert record.failed_attempt.attempt_id == first.attempt_id
    assert record.message.content == "partial"
    assert record.response_id == "response-failed"
    assert record.error == "connection dropped"
    assert record.usage == [observed]
    {:ok, stored} = EphemeralStore.load(table, "retry")
    assert stored.run.context.conversation.provider_failures == [record]
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
  end

  test "failed tool frames never execute or enter replacement input" do
    {pid, _} = start()
    {_, provider} = prompt(pid)
    call = %{id: "failed-call", name: "read", arguments: %{}}

    partial = %{
      id: "failed-message",
      role: :assistant,
      content: [%{type: :text, text: "kept"}, Map.put(call, :type, :tool_call)]
    }

    event = Map.put(failure(:stream), :message, partial)
    send(provider, {:events, [%{type: :tool_call_completed, tool_call: call}, event]})
    {second, provider} = replacement()
    assert List.last(second.messages).content == [%{type: :text, text: "kept"}]
    assert List.last(second.messages).id == "failed-message"
    refute_receive {:tool, _}, 20
    assert [failure] = Conversation.status(pid).conversation.provider_failures
    assert failure.message == partial
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
  end

  test "settled tool history survives retry without executing the tool again" do
    {pid, _} = start()
    {_, provider} = prompt(pid)
    call = %{id: "settled-call", name: "read", arguments: %{}}
    send(provider, {:events, [%{type: :tool_call_completed, tool_call: call}, done("batch")]})
    assert_receive {:tool, "settled-call"}, 1_000
    assert_receive {:provider, before_retry, provider}, 1_000
    send(provider, {:events, [failure(:stream)]})
    {after_retry, provider} = replacement()
    assert after_retry.messages == before_retry.messages

    assert Enum.any?(
             after_retry.messages,
             &(&1[:role] == :tool and &1[:tool_call_id] == "settled-call")
           )

    refute_receive {:tool, _}, 20
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
  end

  test "stream retries stop after five replacements" do
    {pid, _} = start()
    {_, provider} = prompt(pid)

    provider =
      Enum.reduce(1..5, provider, fn count, provider ->
        send(provider, {:events, [failure(:stream)]})

        assert_receive {:agent_runtime, "retry",
                        %{type: :provider_retry_scheduled, retry_count: ^count}},
                       1_000

        accelerate(pid)
        assert_receive {:provider, _, next}, 1_000
        next
      end)

    send(provider, {:events, [failure(:stream)]})
    assert_receive {:agent_runtime, "retry", %{type: :run_failed}}, 1_000
    assert map_size(Conversation.status(pid).run.provider_attempts) == 6
    refute_receive {:provider, _, _}, 20
  end

  test "connection retry continues past five with capped Codex backoff" do
    {pid, _} = start()
    {_, provider} = prompt(pid)

    provider =
      Enum.reduce(
        Enum.with_index([5_000, 10_000, 20_000, 40_000, 60_000, 60_000], 1),
        provider,
        fn {delay, count}, provider ->
          send(provider, {:events, [failure(:connection)]})

          assert_receive {:agent_runtime, "retry",
                          %{
                            type: :provider_retry_scheduled,
                            retry_count: ^count,
                            delay_ms: ^delay
                          }},
                         1_000

          accelerate(pid)
          assert_receive {:provider, _, next}, 1_000
          next
        end
      )

    # Connection failures have their own allowance and cannot consume the five
    # replacement-stream retries.
    send(provider, {:events, [failure(:stream)]})
    {_, provider} = replacement()
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
    assert map_size(Conversation.status(pid).run.provider_attempts) == 8
  end

  test "partial delta fallback and stale prior timers preserve a single active attempt" do
    {pid, _} = start()
    {_, provider} = prompt(pid)

    send(
      provider,
      {:events,
       [
         %{type: :response_started, message: %{role: :assistant, content: []}},
         %{type: :content_text_delta, delta: "first"},
         %{type: :content_text_delta, delta: " second"},
         failure(:stream)
       ]}
    )

    assert_receive {:agent_runtime, "retry", %{type: :provider_retry_scheduled}}, 1_000
    old = :sys.get_state(pid).provider_retry
    accelerate(pid)
    assert_receive {:provider, request, provider}, 1_000
    assert List.last(request.messages).content == [%{type: :text, text: "first second"}]
    send(pid, {:provider_retry, old.token, old.identity})
    refute_receive {:provider, _, _}, 20
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
  end

  test "Store acknowledgement and host Writer acknowledgement both gate retry" do
    {pid, _} = start(store: GatedStore, hooks: Hooks)
    {first, provider} = prompt(pid)
    send(provider, {:events, [failure(:stream, "partial")]})
    assert_receive {:failure_store, store}, 1_000
    refute_receive {:retry_boundary, _, _}, 20
    refute_receive {:provider, _, _}, 20
    send(store, :ack)
    assert_receive {:retry_boundary, snapshot, boundary}, 1_000
    assert snapshot.failed_attempt.attempt_id == first.attempt_id
    assert snapshot.message.content == "partial"
    refute_receive {:agent_runtime, "retry", %{type: :provider_retry_scheduled}}, 20
    send(boundary, :ack)
    {_, provider} = replacement()
    finish(provider)
    assert_receive {:agent_runtime, "retry", %{type: :run_completed}}, 1_000
  end

  test "rejected Store acknowledgement does not start a replacement" do
    {pid, _} = start(store: GatedStore)
    {_, provider} = prompt(pid)
    send(provider, {:events, [failure(:stream)]})
    assert_receive {:failure_store, store}, 1_000
    send(store, :reject)
    assert_receive {:agent_runtime, "retry", %{type: :storage_failed}}, 1_000
    assert Conversation.status(pid).phase == :storage_failed
    refute_receive {:provider, _, _}, 20
  end

  test "rejected Writer acknowledgement does not start a replacement" do
    {pid, _} = start(hooks: Hooks)
    {_, provider} = prompt(pid)
    send(provider, {:events, [failure(:stream)]})
    assert_receive {:retry_boundary, _, boundary}, 1_000
    send(boundary, :reject)
    assert_receive {:agent_runtime, "retry", %{type: :storage_failed}}, 1_000
    refute_receive {:provider, _, _}, 20
  end

  test "cancellation during backoff fences both timer and stale timer delivery" do
    {pid, _} = start()
    {_, provider} = prompt(pid)
    send(provider, {:events, [failure(:connection)]})
    assert_receive {:agent_runtime, "retry", %{type: :provider_retry_scheduled}}, 1_000
    pending = :sys.get_state(pid).provider_retry
    assert :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "retry", %{type: :run_cancelled}}, 1_000
    send(pid, {:provider_retry, pending.token, pending.identity})
    refute_receive {:provider, _, _}, 30
  end

  test "unretired provider cannot settle or dispatch a replacement" do
    {pid, _} =
      start(provider_context: %{test: self(), hold_retirement: true}, provider_idle_timeout: 60)

    {_, provider} = prompt(pid)
    send(provider, {:events, [failure(:stream)]})
    assert_receive {:provider_retiring, ^provider}, 1_000
    assert_receive {:agent_runtime, "retry", %{type: :run_cancelled}}, 1_000
    refute_receive {:provider, _, _}, 20
    assert Conversation.status(pid).phase == :terminal
  end

  test "cold recovery of a pending retry never recreates a timer or provider" do
    {pid, table} = start()
    {_, provider} = prompt(pid)
    send(provider, {:events, [failure(:connection)]})
    assert_receive {:agent_runtime, "retry", %{type: :provider_retry_scheduled}}, 1_000
    {:ok, stored} = EphemeralStore.load(table, "retry")
    stop_supervised!(Conversation)
    {restored, _} = start(run: stored.run, context: table)
    assert Conversation.status(restored).phase == :recovery_required
    refute_receive {:provider, _, _}, 30
    assert :sys.get_state(restored).provider_retry == nil
  end

  test "unclassified terminal failures and opt-out retain terminal behavior" do
    for opts <- [[], [provider_retry: false]] do
      {pid, _} = start(opts)
      {_, provider} = prompt(pid)
      event = if opts == [], do: Map.delete(failure(:stream), :retry), else: failure(:stream)
      send(provider, {:events, [event]})
      assert_receive {:agent_runtime, "retry", %{type: :run_failed}}, 1_000
      refute_receive {:provider, _, _}, 20
      stop_supervised!(Conversation)
    end
  end

  defp start(extra \\ []) do
    {:ok, table} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "read",
        tool_revision: 1,
        schema: %{"type" => "object"},
        safety: %{
          read_only: true,
          retry_safe: true,
          parallel_safe: false,
          requires_approval: false
        },
        backend: Backend,
        backend_context: %{test: self()}
      })

    context = if extra[:store] == GatedStore, do: %{table: table, test: self()}, else: table

    opts =
      Keyword.merge(
        [
          run_id: "retry",
          store: EphemeralStore,
          context: context,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: registry,
          authority: %{caller: "host", run_id: "retry", grants: ["read"], tool_revision: 1},
          provider_retry: %{stream_max_retries: 5, unbounded_connection_retries: true},
          run_timeout: :infinity,
          effect_timeout: 2_000,
          work: :infinity
        ],
        extra
      )

    {start_supervised!({Conversation, opts}, id: Conversation), table}
  end

  defp prompt(pid) do
    assert {:ok, _} = Conversation.prompt(pid, "work")
    assert_receive {:provider, request, provider}, 1_000
    {request, provider}
  end

  defp replacement do
    assert_receive {:agent_runtime, "retry", %{type: :provider_retry_scheduled}}, 1_000
    assert_receive {:provider, request, provider}, 4_000
    {request, provider}
  end

  # Assert the production delay separately, then deliver the same identity-
  # scoped timer in this isolated fixture instead of sleeping through backoff.
  defp accelerate(pid) do
    pending = :sys.get_state(pid).provider_retry
    Process.cancel_timer(pending.timer)
    send(pid, {:provider_retry, pending.token, pending.identity})
  end

  defp done(text), do: %{type: :response_completed, message: %{role: :assistant, content: text}}
  defp finish(provider), do: send(provider, {:events, [done("done")]})

  defp failure(class, text \\ nil, usage \\ nil),
    do: %{
      type: :response_failed,
      error: "connection dropped",
      retry: %{class: class},
      message: if(text, do: %{role: :assistant, content: text}),
      usage: usage,
      response_id: "response-failed"
    }
end
