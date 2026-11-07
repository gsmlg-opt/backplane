defmodule Backplane.AgentRuntime.ConversationProviderSelectionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, context, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Hooks do
    def prepare_provider_selection(snapshot, context) do
      send(context.test, {:prepare_selection, snapshot, context, self()})

      receive do
        {:prepared, result} -> result
      end
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:backend, operation, self()})
      receive do: (:finish -> {:ok, %{text: "settled-tool"}})
    end
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(%{test: test, table: table}, run, meta) do
      if elem(meta.command, 0) == :provider_started and elem(meta.command, 2)[:provider_adoption] do
        send(test, {:adoption_store, meta, self()})

        receive do
          :ack -> EphemeralStore.store(table, run, meta)
          :reject -> {:error, Error.new(:execution_failure, "rejected adoption")}
        end
      else
        EphemeralStore.store(table, run, meta)
      end
    end
  end

  test "native failed-attempt boundary adopts B, preserves tools/history and C pending during preparation" do
    {pid, table} = start()
    {:ok, _} = Conversation.prompt(pid, "keep this turn")
    assert_receive {:provider, first, context, provider}, 1_000
    assert first.provider_selection == %{provider: "provider-a", model: "model-a"}
    assert context.attempt_id == first.attempt_id
    send(provider, {:events, [tool(), done("tool batch")]})
    assert_receive {:backend, _operation, backend}, 1_000
    assert {:ok, b_receipt} = stage(pid, "B")
    send(backend, :finish)
    assert_receive {:provider, second, _, provider}, 1_000
    assert second.provider_selection == first.provider_selection
    assert second.turn_id == first.turn_id
    canonical = second.messages

    assert Enum.any?(
             canonical,
             &(&1[:role] == :tool and get_in(&1, [:result, :text]) == "settled-tool")
           )

    send(provider, {:events, [usage(7), failed(:retry)]})
    assert_receive {:prepare_selection, snapshot, prep_context, preparation}, 1_000
    assert snapshot.pending == b_receipt |> Map.delete(:store_mode)
    assert snapshot.boundary.failed_attempt.attempt_id == second.attempt_id
    refute Map.has_key?(prep_context, :interact)
    refute Map.has_key?(prep_context, :provider_emit)
    assert {:ok, c_receipt} = stage(pid, "C")

    send(
      preparation,
      {:prepared,
       {:ok,
        %{provider: "provider-b", model: "model-b", provider_context: %{token: "ephemeral-b", provider_emit: :forged, catalog_snapshot: :forged}}}}
    )

    assert_receive {:agent_runtime, "selection-run",
                    %{type: :provider_selection_adopted} = adoption},
                   1_000

    assert_receive {:provider, third, third_context, provider}, 1_000
    assert third.provider_selection.request_id == "B"
    assert third.messages == canonical
    assert third.turn_id == second.turn_id
    assert third_context.token == "ephemeral-b"
    assert is_function(third_context.provider_emit, 1)
    assert is_map(third_context.catalog_snapshot)
    assert third_context.attempt_id == third.attempt_id
    assert adoption.attempt_id == third.attempt_id
    status = Conversation.status(pid)
    assert status.provider_selection.pending.generation == c_receipt.generation

    assert status.run.provider_attempts[third.attempt_id].provider_selection ==
             third.provider_selection

    assert status.conversation.usage == [
             %{input_tokens: 7, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0}
           ]

    assert status.run.execution_budget.used == 4
    {:ok, stored} = EphemeralStore.load(table, "selection-run")
    refute inspect(stored.run) =~ "ephemeral-b"
    send(provider, {:events, [failed(:retry)]})

    assert_receive {:prepare_selection, %{pending: %{request: %{request_id: "C"}}}, _, prep},
                   1_000

    send(prep, {:prepared, {:ok, %{provider: "provider-c", model: "model-c"}}})
    assert_receive {:provider, fourth, _, provider}, 1_000
    assert fourth.provider_selection.request_id == "C"
    send(provider, {:events, [done("finished")]})
    assert_receive {:agent_runtime, "selection-run", %{type: :run_completed}}, 1_000
    refute_receive {:backend, _, _}, 20
  end

  test "compacted provider view preserves canonical history and appends later tool suffixes" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "canonical input")
    assert_receive {:provider, first, _, provider}, 1_000
    assert {:ok, _} = stage(pid, "compact")
    send(provider, {:events, [failed(:compaction)]})
    assert_receive {:prepare_selection, _, _, prep}, 1_000
    compact = [%{role: :user, content: "host-owned compact view"}]
    send(prep, {:prepared, {:ok, %{provider: "b", model: "b", messages: compact}}})
    assert_receive {:provider, second, _, provider}, 1_000
    assert second.messages == compact
    assert Conversation.status(pid).messages == first.messages
    send(provider, {:events, [tool(), done("tool batch")]})
    assert_receive {:backend, _, backend}, 1_000
    send(backend, :finish)
    assert_receive {:provider, third, _, provider}, 1_000
    assert Enum.take(third.messages, 1) == compact
    canonical = Conversation.status(pid).messages
    assert Enum.take(canonical, 1) == first.messages
    assert Enum.drop(third.messages, 1) == Enum.drop(canonical, length(first.messages))
    send(provider, {:events, [done("finished")]})
    assert_receive {:agent_runtime, "selection-run", %{type: :run_completed}}, 1_000
  end

  test "default reset is pinned at preparation and storage acknowledgement gates dispatch" do
    {pid, _} = start(store: GatedStore)
    {:ok, _} = Conversation.prompt(pid, "reset")
    assert_receive {:provider, _, _, provider}, 1_000
    assert {:ok, _} = stage(pid, "reset", :reset)
    send(provider, {:events, [failed(:retry)]})

    assert_receive {:prepare_selection, %{pending: %{request: %{mode: :reset, intent: %{}}}}, _,
                    prep},
                   1_000

    send(prep, {:prepared, {:ok, %{provider: "default", model: "default-model"}}})
    assert_receive {:adoption_store, meta, store}, 1_000
    assert elem(meta.command, 2).provider_adoption.request_id == "reset"
    refute_receive {:provider, _, _, _}, 20
    refute_receive {:agent_runtime, "selection-run", %{type: :provider_selection_adopted}}, 20
    send(store, :ack)
    assert_receive {:provider, request, _, provider}, 1_000
    assert request.provider_selection.provider == "default"
    send(provider, {:events, [done("ok")]})
    assert_receive {:agent_runtime, "selection-run", %{type: :run_completed}}, 1_000
  end

  test "failed adoption acknowledgement and exhausted work never dispatch a replacement" do
    for options <- [[store: GatedStore], [work: 1]] do
      {pid, _} = start(options)
      {:ok, _} = Conversation.prompt(pid, "bounded adoption")
      assert_receive {:provider, _, _, provider}, 1_000
      assert {:ok, _} = stage(pid, "B")
      send(provider, {:events, [failed(:retry)]})
      assert_receive {:prepare_selection, _, _, prep}, 1_000
      send(prep, {:prepared, {:ok, %{provider: "b", model: "b"}}})

      if options[:store] == GatedStore do
        assert_receive {:adoption_store, _, store}, 1_000
        send(store, :reject)
      end

      assert_terminal(pid)
      assert Conversation.status(pid).provider_selection.pending.request.request_id == "B"
      refute_receive {:provider, _, _, _}, 20
      refute_receive {:agent_runtime, "selection-run", %{type: :provider_selection_adopted}}, 20
    end
  end

  test "published text, thinking, tool and hosted output make classified failures terminal" do
    for event <- [
          %{type: :content_text_delta, delta: "published"},
          %{type: :content_thinking_delta, delta: "thought"},
          tool(),
          %{type: :provider_hosted_event, event: %{type: "performed"}}
        ] do
      {pid, _} = start()
      {:ok, _} = Conversation.prompt(pid, "not replayable")
      assert_receive {:provider, first, _, provider}, 1_000
      assert {:ok, _} = stage(pid, "pending")
      send(provider, {:events, [event, failed(:retry)]})
      assert_receive {:agent_runtime, "selection-run", %{type: :run_failed}}, 1_000
      status = Conversation.status(pid)
      assert status.run.provider_attempts[first.attempt_id].replay_blocked
      assert status.provider_selection.pending.request.request_id == "pending"
      refute_receive {:prepare_selection, _, _, _}, 20
    end
  end

  test "cancelled, failed and timed-out preparation cannot dispatch replacements" do
    for action <- [:cancel, :failure, :timeout, :crash] do
      {pid, _} = start(effect_timeout: 100)
      {:ok, _} = Conversation.prompt(pid, "prepare")
      assert_receive {:provider, _, _, provider}, 1_000
      assert {:ok, _} = stage(pid, "B")
      send(provider, {:events, [failed(:retry)]})
      assert_receive {:prepare_selection, _, _, prep}, 1_000

      case action do
        :cancel ->
          assert :ok = Conversation.cancel(pid)

        :failure ->
          send(prep, {:prepared, {:error, Error.new(:execution_failure, "prepare failed")}})

        :timeout ->
          :ok

        :crash ->
          Process.exit(prep, :kill)
      end

      assert_terminal(pid)
      send(prep, {:prepared, {:ok, %{provider: "late", model: "late"}}})
      refute_receive {:provider, _, _, _}, 20
      refute_receive {:agent_runtime, "selection-run", %{type: :provider_selection_adopted}}, 20
    end
  end

  test "restored runs dispatch nothing and fixed provider failures retain their behavior" do
    {pid, _} = start(hooks: nil, provider_selection: nil)
    {:ok, _} = Conversation.prompt(pid, "fixed")
    assert_receive {:provider, request, _, provider}, 1_000
    refute Map.has_key?(request, :provider_selection)
    assert {:error, _} = stage(pid, "unsupported")
    send(provider, {:events, [failed(:retry)]})
    assert_receive {:agent_runtime, "selection-run", %{type: :run_failed}}, 1_000
    run = Conversation.status(pid).run
    run = %{run | state: :running}
    {_restored, _} = start(run: run)
    refute_receive {:provider, _, _, _}, 30
  end

  test "staging validates exact identity, bounds and request idempotency" do
    {pid, _} = start()
    {:ok, _} = Conversation.prompt(pid, "stage")
    assert_receive {:provider, _, _, provider}, 1_000
    request = request(pid, "B", :select)
    assert {:ok, first} = Conversation.stage_provider_selection(pid, request)
    assert {:ok, ^first} = Conversation.stage_provider_selection(pid, request)

    assert {:error, _} =
             Conversation.stage_provider_selection(pid, %{request | intent: %{model: "other"}})

    assert {:error, _} = Conversation.stage_provider_selection(pid, %{request | incarnation: 99})

    assert {:error, _} =
             Conversation.stage_provider_selection(pid, Map.put(request, :extra, self()))

    assert {:error, _} =
             Conversation.stage_provider_selection(pid, %{
               request
               | request_id: "large",
                 intent: %{value: String.duplicate("x", 17_000)}
             })

    send(provider, {:events, [done("end")]})
    assert_receive {:agent_runtime, "selection-run", %{type: :run_completed}}, 1_000
  end

  defp start(opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "fixture",
        tool_revision: 1,
        description: "fixture",
        schema: %{"type" => "object", "properties" => %{}},
        safety: %{
          read_only: true,
          retry_safe: true,
          parallel_safe: false,
          requires_approval: false
        },
        backend: Backend,
        backend_context: %{test: self()}
      })

    context = if opts[:store] == GatedStore, do: %{test: self(), table: table}, else: table

    runtime =
      Keyword.merge(
        [
          run_id: "selection-run",
          incarnation: 1,
          store: EphemeralStore,
          context: context,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          hooks: Hooks,
          provider_selection: %{provider: "provider-a", model: "model-a"},
          registry: registry,
          authority: %{
            caller: "host",
            run_id: "selection-run",
            grants: ["fixture"],
            tool_revision: 1
          },
          work: 20,
          run_timeout: 5_000
        ],
        opts
      )

    {start_supervised!({Conversation, runtime}, id: make_ref()), table}
  end

  defp stage(pid, id, mode \\ :select),
    do: Conversation.stage_provider_selection(pid, request(pid, id, mode))

  defp request(pid, id, mode) do
    status = Conversation.status(pid)

    %{
      run_id: status.run.run_id,
      incarnation: status.run.incarnation,
      turn_id: status.conversation.turn_id,
      request_id: id,
      mode: mode,
      intent: if(mode == :reset, do: %{}, else: %{model: id})
    }
  end

  defp failed(recovery),
    do: %{type: :response_failed, error: %{class: :context_exceeded}, recovery: recovery}

  defp done(text), do: %{type: :response_completed, message: %{role: :assistant, content: text}}

  defp tool,
    do: %{
      type: :tool_call_completed,
      tool_call: %{id: "fixture-1", name: "fixture", arguments: %{}}
    }

  defp usage(tokens),
    do: %{
      type: :usage_updated,
      usage: %{input_tokens: tokens, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0}
    }

  defp assert_terminal(pid, remaining \\ 100)
  defp assert_terminal(_pid, 0), do: flunk("conversation did not settle")

  defp assert_terminal(pid, remaining) do
    if Conversation.status(pid).phase in [:terminal, :storage_failed] do
      :ok
    else
      Process.sleep(10)
      assert_terminal(pid, remaining - 1)
    end
  end
end
