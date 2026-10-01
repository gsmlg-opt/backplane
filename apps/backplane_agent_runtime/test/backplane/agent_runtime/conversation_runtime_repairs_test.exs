defmodule Backplane.AgentRuntime.ConversationRuntimeRepairsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  # Shared-runtime integration: no JavaScript engine or substitute dispatcher.
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

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool, operation, self()})
      loop(operation.backend_context)
    end

    defp loop(context) do
      receive do
        {:nested, name} ->
          result = context.nested_dispatch.(%{tool_name: name, arguments: %{}})
          send(context.test, {:nested_result, name, result})
          loop(context)

        {:stage, update} ->
          send(context.test, {:stager, context.stage_catalog})
          send(context.test, {:staged, context.stage_catalog.(update)})
          loop(context)

        :ask ->
          send(context.test, {:answer, context.interact.(%{kind: :permission})})
          loop(context)

        {:result, result} ->
          result
      end
    end
  end

  defmodule BarrierStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      command = meta.command

      gate =
        case command do
          {:conversation_updated, _, %{conversation: %{pending_interaction: interaction}}}
          when not is_nil(interaction) ->
            :interaction

          {:conversation_updated, _, %{conversation: %{pending_interaction: nil}}} ->
            :resolution

          {:tool_completed, _, %{tool_name: "a"}} ->
            :nested_settlement

          _ ->
            nil
        end

      if gate && :ets.member(context.gates, gate) do
        :ets.delete(context.gates, gate)
        send(context.test, {:store_barrier, gate, self()})

        receive do
          :ack ->
            EphemeralStore.store(context.table, run, meta)

          :lose_ack ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)

            receive do
              :never -> :ok
            end
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  for nested? <- [false, true] do
    test "#{if nested?, do: "nested", else: "direct"} interaction rejects stale timer generations and enforces resumed budget" do
      {pid, _table, _gates} = start()
      {outer, tool} = begin_tool(pid, unquote(nested?))
      old = :sys.get_state(pid)
      send(tool, :ask)

      assert_receive {:agent_runtime, "repairs",
                      %{type: :interaction_requested, interaction_id: id}}

      paused = :sys.get_state(pid)
      assert paused.paused_run_remaining <= old.limits.run
      stale_timeouts(pid, old)
      assert Conversation.status(pid).phase == :waiting_interaction
      assert :ok = Conversation.resolve(pid, id, :allow)
      assert_receive {:answer, {:ok, :allow}}
      resumed = :sys.get_state(pid)

      assert resumed.effect_live_deadline - System.monotonic_time(:millisecond) <=
               paused.paused_effect_remaining

      assert resumed.run.deadline - System.system_time(:millisecond) <=
               paused.paused_run_remaining

      if unquote(nested?) do
        assert resumed.nested.live_deadline - System.monotonic_time(:millisecond) <=
                 paused.paused_nested_remaining
      end

      stale_timeouts(pid, old)
      assert Conversation.status(pid).phase == :running
      assert resumed.effect.timer_generation != Map.get(old.effect, :timer_generation)

      if unquote(nested?) do
        assert resumed.nested.timer_generation != Map.get(old.nested, :timer_generation)
      end

      # A valid current generation still wins, and duplicate delivery settles once.
      message = deadline_message(resumed)
      send(pid, message)
      send(pid, message)
      assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
      refute_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 20
      assert {:error, %Error{}} = Conversation.resolve(pid, id, :late)
      refute Process.alive?(outer)
      refute Process.alive?(tool)
    end
  end

  for winner <- [:timeout, :cancel], nested? <- [false, true] do
    test "#{if nested?, do: "nested", else: "direct"} interaction admission acknowledgement cannot resurrect execution after #{winner}" do
      {pid, _table, gates} = start()
      :ets.insert(gates, {:interaction, true})
      {_outer, tool} = begin_tool(pid, unquote(nested?))
      send(tool, :ask)
      assert_receive {:store_barrier, :interaction, store}
      state = :sys.get_state(pid)

      if unquote(winner) == :cancel,
        do: Conversation.cancel(pid),
        else: send(pid, deadline_message(state))

      assert Conversation.status(pid).phase == :cancelling
      send(store, :ack)
      assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
      refute_receive {:agent_runtime, "repairs", %{type: :interaction_requested}}, 20
      refute_receive {:provider, _, _}, 20
      assert Conversation.status(pid).conversation.pending_interaction == nil
    end
  end

  for failure <- [:error, :error_marked, :timeout, :crash, :cancelled] do
    test "failed nested producer #{failure} releases staging and callbacks before settlement acknowledgement" do
      {pid, table, gates} = start()
      {outer, producer} = begin_tool(pid, true)
      a = update("a-publication", "only-a")
      b = update("b-publication", "only-b")
      send(producer, {:stage, a})
      assert_receive {:stager, stale}
      assert_receive {:staged, {:ok, %{status: :staged}}}
      :ets.insert(gates, {:nested_settlement, true})

      case unquote(failure) do
        :error ->
          send(producer, {:result, {:error, Error.new(:execution_failure, "producer failed")}})

        :error_marked ->
          send(producer, {:result, {:ok, %{is_error: true, text: "failed"}}})

        :timeout ->
          send(pid, nested_message(:sys.get_state(pid)))

        :crash ->
          Process.exit(producer, :kill)

        :cancelled ->
          send(producer, {:result, {:error, Error.new(:cancelled, "producer cancelled")}})
      end

      assert_receive {:store_barrier, :nested_settlement, settlement}, 1_000
      assert Conversation.status(pid).pending_catalog_publication == nil
      assert {:error, %Error{class: :resource_conflict}} = stale.(a)
      send(settlement, :ack)
      assert_receive {:nested_result, "a", _}
      send(outer, {:nested, "b"})
      assert_receive {:tool, %{tool_name: "b", catalog_revision: 1}, second}
      send(second, {:stage, b})
      assert_receive {:stager, _}
      assert_receive {:staged, {:ok, %{publication_id: "b-publication", status: :staged}}}
      assert {:error, %Error{class: :resource_conflict}} = stale.(a)
      send(second, {:result, {:ok, %{text: "discovered"}}})
      assert_receive {:nested_result, "b", {:ok, _}}
      assert Conversation.status(pid).catalog_revision == 1
      send(outer, {:result, {:ok, %{text: "handled"}}})
      assert_receive {:provider, request, provider}, 1_000
      assert request.catalog_revision == 2
      assert Enum.map(request.tools, & &1.name) |> Enum.sort() == ["a", "b", "only-b", "outer"]
      state = :sys.get_state(pid)
      assert Map.has_key?(state.catalog.registry.tools, "only-b")
      refute Map.has_key?(state.catalog.registry.tools, "only-a")
      assert Enum.sort(state.catalog.authority.grants) == ["a", "b", "only-b", "outer"]
      assert state.catalog.publication_id == "b-publication"
      assert [%{publication_id: "b-publication", receipt: receipt}] = state.catalog_receipts

      assert receipt == %{
               publication_id: "b-publication",
               catalog_revision: 2,
               status: :published
             }

      send(
        provider,
        {:events,
         [
           %{
             type: :tool_call_completed,
             tool_call: %{id: "published-call", name: "only-b", arguments: %{}}
           },
           done()
         ]}
      )

      assert_receive {:tool,
                      %{tool_name: "only-b", catalog_revision: 2, tool_revision: 1} = operation,
                      published},
                     1_000

      assert Enum.sort(operation.effective_authority.grants) == ["a", "b", "only-b", "outer"]
      send(published, {:result, {:ok, %{text: "new catalog authorized"}}})
      assert_receive {:provider, %{catalog_revision: 2}, final_provider}
      send(final_provider, {:events, [done()]})
      assert_receive {:agent_runtime, "repairs", %{type: :run_completed}}, 1_000
      assert {:ok, %{run: %{active_tools: active}}} = EphemeralStore.load(table, "repairs")
      assert active == %{}
    end
  end

  test "explicit uncertain nested producer revokes staging before uncertain run settlement" do
    {pid, table, _gates} = start()
    {_outer, producer} = begin_tool(pid, true)
    a = update("a-publication", "only-a")
    send(producer, {:stage, a})
    assert_receive {:stager, stale}
    assert_receive {:staged, {:ok, %{status: :staged}}}
    send(producer, {:result, {:error, Error.new(:unknown_outcome, "producer uncertain")}})

    assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled, state: :unknown_outcome}},
                   1_000

    assert Conversation.status(pid).pending_catalog_publication == nil
    assert {:error, %Error{class: :resource_conflict}} = stale.(a)

    assert {:ok, %{run: %{state: :unknown_outcome, active_tools: active}}} =
             EphemeralStore.load(table, "repairs")

    assert Enum.any?(active, fn {_id, invocation} -> invocation.tool_name == "a" end)
    refute_receive {:provider, _, _}, 20
  end

  test "lost nested settlement acknowledgement cannot publish successful staging or retain callbacks" do
    {pid, _table, gates} = start(commit_timeout: 250)
    {_outer, producer} = begin_tool(pid, true)
    a = update("a-publication", "only-a")
    send(producer, {:stage, a})
    assert_receive {:stager, stale}
    assert_receive {:staged, {:ok, _}}
    :ets.insert(gates, {:nested_settlement, true})
    send(producer, {:result, {:ok, %{text: "success"}}})
    assert_receive {:store_barrier, :nested_settlement, settlement}
    refute :sys.get_state(pid).pending_catalog.producer_settled?
    assert {:error, %Error{class: :resource_conflict}} = stale.(a)
    send(settlement, :lose_ack)
    assert_receive {:agent_runtime, "repairs", %{type: :storage_failed}}, 1_000
    assert Conversation.status(pid).catalog_revision == 1
    assert Conversation.status(pid).pending_catalog_publication == nil
    refute_receive {:provider, _, _}, 20
  end

  for nested? <- [false, true] do
    test "cancellation while #{if nested?, do: "nested", else: "direct"} interaction waits rejects late replies" do
      {pid, _table, _gates} = start()
      {outer, tool} = begin_tool(pid, unquote(nested?))
      send(tool, :ask)

      assert_receive {:agent_runtime, "repairs",
                      %{type: :interaction_requested, interaction_id: id}}

      assert :ok = Conversation.cancel(pid)
      assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
      assert {:error, %Error{}} = Conversation.resolve(pid, id, :late)
      refute Process.alive?(outer)
      refute Process.alive?(tool)
      refute_receive {:provider, _, _}, 20
      refute_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 20
    end
  end

  test "nested current generation enforces its remaining budget after interaction" do
    {pid, _table, _gates} = start()
    {outer, tool} = begin_tool(pid, true)
    send(tool, :ask)

    assert_receive {:agent_runtime, "repairs",
                    %{type: :interaction_requested, interaction_id: id}}

    assert :ok = Conversation.resolve(pid, id, :allow)
    assert_receive {:answer, {:ok, :allow}}
    state = :sys.get_state(pid)
    message = nested_message(state)
    send(pid, message)
    send(pid, message)
    assert_receive {:nested_result, "a", {:error, %Error{class: :timeout}}}, 1_000
    refute_receive {:nested_result, "a", _}, 20
    assert Conversation.status(pid).phase == :running
    send(outer, {:result, {:ok, %{text: "timeout handled"}}})
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "repairs", %{type: :run_completed}}, 1_000
  end

  test "effect current generation enforces its remaining budget after interaction" do
    {pid, _table, _gates} = start()
    {_outer, tool} = begin_tool(pid, false)
    send(tool, :ask)

    assert_receive {:agent_runtime, "repairs",
                    %{type: :interaction_requested, interaction_id: id}}

    assert :ok = Conversation.resolve(pid, id, :allow)
    assert_receive {:answer, {:ok, :allow}}
    state = :sys.get_state(pid)
    send(pid, {:timeout, state.effect.task.ref, state.effect.timer_generation})
    assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
    refute Process.alive?(tool)
  end

  test "input checkpoint and nested result retain a single commit slot and both transitions" do
    {pid, table, gates} = start()
    {outer, producer} = begin_tool(pid, true)
    :ets.insert(gates, {:nested_settlement, true})
    send(producer, {:result, {:ok, %{text: "nested result"}}})
    assert_receive {:store_barrier, :nested_settlement, settlement}
    before = :sys.get_state(pid)
    caller = Task.async(fn -> Conversation.follow_up(pid, "queued input") end)
    # Synchronize the caller through the server mailbox before releasing the Store.
    eventually(fn -> :queue.len(:sys.get_state(pid).jobs) == 1 end)
    assert :sys.get_state(pid).commit.task.ref == before.commit.task.ref
    send(settlement, :ack)
    assert_receive {:nested_result, "a", {:ok, %{text: "nested result"}}}
    assert {:ok, _} = Task.await(caller)
    assert {:ok, %{run: run}} = EphemeralStore.load(table, "repairs")
    assert Enum.any?(run.context.conversation.follow_up, &(&1.content == "queued input"))
    assert map_size(run.tool_results) == 1
    send(outer, {:result, {:ok, %{text: "outer result"}}})
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done()]})
    assert_receive {:provider, request, follow_up}
    assert Enum.any?(request.messages, &(&1[:content] == "queued input"))
    send(follow_up, {:events, [done()]})
    assert_receive {:agent_runtime, "repairs", %{type: :run_completed}}, 1_000
  end

  defp eventually(assertion, attempts \\ 100)
  defp eventually(assertion, 0), do: assert(assertion.())

  defp eventually(assertion, attempts) do
    if assertion.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          eventually(assertion, attempts - 1)
        )
  end

  test "nested worker death while human waiting stops conservatively and clears persisted interaction" do
    {pid, table, _gates} = start()
    {outer, producer} = begin_tool(pid, true)
    send(producer, :ask)

    assert_receive {:agent_runtime, "repairs",
                    %{type: :interaction_requested, interaction_id: id}}

    Process.exit(producer, :kill)
    assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
    assert {:error, %Error{}} = Conversation.resolve(pid, id, :late)
    refute Process.alive?(outer)
    assert {:ok, %{run: run}} = EphemeralStore.load(table, "repairs")
    assert run.context.conversation.pending_interaction == nil
    assert Conversation.status(pid).run.state == :unknown_outcome
    refute_receive {:provider, _, _}, 20
  end

  test "resolution acknowledgement racing cancellation never resumes waiting effects" do
    {pid, table, gates} = start()
    {outer, producer} = begin_tool(pid, true)
    send(producer, :ask)

    assert_receive {:agent_runtime, "repairs",
                    %{type: :interaction_requested, interaction_id: id}}

    :ets.insert(gates, {:resolution, true})
    caller = Task.async(fn -> Conversation.resolve(pid, id, :allow) end)
    assert_receive {:store_barrier, :resolution, store}
    assert :ok = Conversation.cancel(pid)
    assert {:error, %Error{class: :cancelled}} = Task.await(caller)
    send(store, :ack)
    assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
    refute Process.alive?(outer)
    refute Process.alive?(producer)
    refute_receive {:answer, {:ok, :allow}}, 20
    refute_receive {:agent_runtime, "repairs", %{type: :interaction_resolved}}, 20
    assert {:ok, %{run: run}} = EphemeralStore.load(table, "repairs")
    assert run.context.conversation.pending_interaction == nil
  end

  for cancel? <- [false, true] do
    test "nested result queued behind input checkpoint preserves commit ownership#{if cancel?, do: " under cancellation", else: ""}" do
      {pid, table, gates} = start()
      {outer, producer} = begin_tool(pid, true)
      :ets.insert(gates, {:resolution, true})
      input = Task.async(fn -> Conversation.follow_up(pid, "overlapping input") end)
      assert_receive {:store_barrier, :resolution, store}
      commit_ref = :sys.get_state(pid).commit.task.ref
      send(producer, {:result, {:ok, %{text: "queued nested"}}})
      eventually(fn -> :queue.len(:sys.get_state(pid).commit_queue) == 1 end)
      assert :sys.get_state(pid).commit.task.ref == commit_ref

      if unquote(cancel?) do
        assert :ok = Conversation.cancel(pid)
        assert {:error, %Error{class: :cancelled}} = Task.await(input)
        send(store, :ack)
        assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
        refute Process.alive?(outer)
        refute_receive {:provider, _, _}, 20
        refute_receive {:nested_result, "a", {:ok, _}}, 20
      else
        send(store, :ack)
        assert {:ok, _} = Task.await(input)
        assert_receive {:nested_result, "a", {:ok, %{text: "queued nested"}}}
        assert {:ok, %{run: run}} = EphemeralStore.load(table, "repairs")
        assert Enum.any?(run.context.conversation.follow_up, &(&1.content == "overlapping input"))
        assert map_size(run.tool_results) == 1
        assert :ok = Conversation.cancel(pid)
        assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
      end
    end
  end

  test "enclosing cancellation revokes nested staging and captured callbacks" do
    {pid, _table, _gates} = start()
    {_outer, producer} = begin_tool(pid, true)
    a = update("a-publication", "only-a")
    send(producer, {:stage, a})
    assert_receive {:stager, stale}
    assert_receive {:staged, {:ok, _}}
    assert :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "repairs", %{type: :run_cancelled}}, 1_000
    assert {:error, %Error{class: :resource_conflict}} = stale.(a)
    assert Conversation.status(pid).pending_catalog_publication == nil
    assert Conversation.status(pid).catalog_revision == 1
    assert :sys.get_state(pid).catalog_receipts == []
  end

  test "nested timeout wins interaction admission acknowledgement without pausing the enclosing run" do
    {pid, _table, gates} = start()
    {outer, producer} = begin_tool(pid, true)
    :ets.insert(gates, {:interaction, true})
    send(producer, :ask)
    assert_receive {:store_barrier, :interaction, store}
    send(pid, nested_message(:sys.get_state(pid)))
    eventually(fn -> is_nil(:sys.get_state(pid).nested.task) end)
    send(store, :ack)
    assert_receive {:nested_result, "a", {:error, %Error{class: :timeout}}}, 1_000
    refute_receive {:agent_runtime, "repairs", %{type: :interaction_requested}}, 20
    state = :sys.get_state(pid)
    assert state.phase == :running
    assert state.interaction == nil
    assert state.conversation.pending_interaction == nil
    assert is_reference(state.timer_generation)
    assert is_reference(state.effect.timer_generation)
    send(outer, {:nested, "b"})
    assert_receive {:tool, %{tool_name: "b"}, second}
    send(second, {:result, {:ok, %{text: "valid retry"}}})
    assert_receive {:nested_result, "b", {:ok, _}}
    send(outer, {:result, {:ok, %{text: "handled"}}})
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "repairs", %{type: :run_completed}}, 1_000
  end

  defp start(opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)
    gates = :ets.new(:repair_gates, [:set, :public])
    registry = registry(["outer", "a", "b"])

    pid =
      start_supervised!(
        {Conversation,
         Keyword.merge(
           [
             run_id: "repairs",
             incarnation: 1,
             store: BarrierStore,
             context: %{table: table, gates: gates, test: self()},
             provider: Provider,
             provider_context: %{test: self()},
             subscriber: self(),
             registry: registry,
             authority: authority(["outer", "a", "b"]),
             tools: definitions(registry),
             work: 40,
             run_timeout: 5_000,
             effect_timeout: 3_000
           ],
           opts
         )},
        id: make_ref()
      )

    {pid, table, gates}
  end

  defp begin_tool(pid, nested?) do
    assert {:ok, _} = Conversation.prompt(pid, "start")
    assert_receive {:provider, _, provider}

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "outer-call", name: "outer", arguments: %{}}
         },
         done()
       ]}
    )

    assert_receive {:tool, %{tool_name: "outer"}, outer}, 1_000

    if nested? do
      send(outer, {:nested, "a"})
      assert_receive {:tool, %{tool_name: "a"}, nested}, 1_000
      {outer, nested}
    else
      {outer, outer}
    end
  end

  defp registry(names) do
    Enum.reduce(names, %ToolRegistry{}, fn name, registry ->
      {:ok, registry} =
        ToolRegistry.register(registry, %{
          tool_name: name,
          tool_revision: 1,
          description: name,
          schema: %{"type" => "object", "properties" => %{}},
          safety: %{read_only: true, retry_safe: true, parallel_safe: false},
          backend: Backend,
          backend_context: %{test: self()}
        })

      registry
    end)
  end

  defp update(id, extra) do
    names = ["outer", "a", "b", extra]
    registry = registry(names)

    %{
      publication_id: id,
      run_id: "repairs",
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: registry,
        authority: authority(names),
        tools: definitions(registry)
      }
    }
  end

  defp definitions(registry),
    do:
      Enum.map(registry.tools, fn {name, descriptor} ->
        %{name: name, description: descriptor.description, parameters: descriptor.schema}
      end)

  defp authority(names), do: %{caller: "host", run_id: "repairs", grants: names, tool_revision: 1}
  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp deadline_message(state) do
    if generation = Map.get(state, :timer_generation),
      do: {:deadline, state.run.run_id, state.run.incarnation, generation},
      else: :deadline
  end

  defp nested_message(state) do
    if generation = Map.get(state.nested, :timer_generation),
      do: {:nested_timeout, state.nested.task.ref, generation},
      else: {:nested_timeout, state.nested.task.ref}
  end

  defp stale_timeouts(pid, state) do
    send(pid, deadline_message(state))

    send(
      pid,
      if(generation = Map.get(state.effect, :timer_generation),
        do: {:timeout, state.effect.task.ref, generation},
        else: {:timeout, state.effect.task.ref}
      )
    )

    if state.nested, do: send(pid, nested_message(state))
    Conversation.status(pid)
  end
end
