defmodule Backplane.AgentRuntime.Codex.MultiAgentInteractionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

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
    def prepare_tool(_invocation, context) do
      send(context.test, {:preparation, self()})

      receive do
        {:ask, request} ->
          send(context.test, {:preparation_answer, context.interact.(request)})
          :allow

        :allow ->
          :allow
      end
    end
  end

  defmodule Backend do
    def execute(operation) do
      context = operation.backend_context
      send(context.test, {:backend, self()})
      loop(context)
    end

    defp loop(context) do
      receive do
        {:ask, request} ->
          send(context.test, {:backend_answer, context.interact.(request)})
          loop(context)

        {:feedback, payload} ->
          send(context.test, {:feedback_answer, context.append_feedback.(payload)})
          loop(context)

        :finish ->
          {:ok, %{text: "done"}}
      end
    end
  end

  defmodule Store do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      resolution? =
        match?(
          {:conversation_updated, _, %{conversation: %{pending_interaction: nil}}},
          meta.command
        )

      checkpoint =
        cond do
          match?({:cleanup_settled, _, _}, meta.command) and
              :ets.take(context.gates, :cancellation) != [] ->
            :cancellation_checkpoint

          resolution? and :ets.take(context.gates, :resolution) != [] ->
            :resolution_checkpoint

          true ->
            nil
        end

      if checkpoint do
        send(context.test, {checkpoint, self()})

        receive do
          :ack ->
            EphemeralStore.store(context.table, run, meta)

          :fail ->
            {:error, Error.new(:execution_failure, "resolution persistence failed")}

          :lose_ack ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)
            receive do: (:never -> :ok)
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  defp start_runtime(max_threads \\ 4) do
    test_pid = self()
    gates = :ets.new(:interaction_gates, [:set, :public])
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "question",
        tool_revision: 1,
        schema: schema,
        safety: %{read_only: true, retry_safe: true, parallel_safe: false},
        backend: Backend,
        backend_context: %{test: test_pid}
      })

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: %{caller: "host", run_id: "root", grants: ["question"]},
         max_concurrent_threads_per_session: max_threads,
         child_options: fn _request, run_id, context ->
           {:ok, table} = EphemeralStore.new(1)
           :ets.insert(gates, {{:store, run_id}, table})
           send(test_pid, {:child_options, run_id, context})

           {:ok,
            [
              run_id: run_id,
              store: Store,
              context: %{table: table, gates: gates, test: test_pid},
              provider: Provider,
              provider_context: %{test: test_pid},
              hooks: Hooks,
              registry: registry,
              tools: [%{name: "question", parameters: schema}],
              authority: %{
                caller: "host",
                run_id: run_id,
                grants: ["question"],
                tool_revision: 1
              },
              schema_admission: :strict,
              work: 20,
              run_timeout: :infinity
            ]}
         end},
        id: make_ref()
      )

    assert {:ok, _} = MultiAgent.subscribe(runtime)
    {runtime, gates}
  end

  defp call(runtime, tool, arguments, profile \\ :v2) do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: profile},
      run_id: "root",
      tool_name: tool,
      arguments: arguments
    })
  end

  defp spawn_child(runtime, name \\ "worker") do
    assert {:ok, _} =
             call(runtime, "spawn_agent", %{"task_name" => name, "message" => "work"})

    assert_receive {:child_options, run_id, _}
    assert_receive {:provider, %{run_id: ^run_id}, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "question", name: "question", arguments: %{}}
         },
         %{type: :response_completed, message: %{role: :assistant, content: "asking"}}
       ]}
    )

    assert_receive {:preparation, hook}, 1_000
    %{name: "/root/" <> name, run_id: run_id, hook: hook}
  end

  defp backend(child) do
    send(child.hook, :allow)
    assert_receive {:backend, worker}, 1_000
    worker
  end

  defp ask(worker, request \\ %{kind: :permission, message: "Continue?"}) do
    send(worker, {:ask, request})
    assert_receive {:codex_collaboration, %{type: :interaction_requested} = event}, 1_000
    event
  end

  defp record(runtime, name) do
    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    Enum.find(snapshot.agents, &(&1.name == name))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end

  for producer <- [:preparation, :backend] do
    test "#{producer} requests and resolutions use the public revisioned manager stream" do
      {runtime, _} = start_runtime()
      child = spawn_child(runtime)
      worker = if unquote(producer) == :preparation, do: child.hook, else: backend(child)
      requested = ask(worker)
      pending = requested.agent.pending_interaction

      assert requested.agent.status == :running
      assert pending.id == requested.interaction_id
      assert pending.request == %{"kind" => "permission", "message" => "Continue?"}

      assert pending.correlation == %{
               manager_id: requested.manager_id,
               agent_id: requested.agent.agent_id,
               run_id: child.run_id,
               incarnation: requested.agent.incarnation,
               interaction_id: pending.id
             }

      assert is_binary(JSON.encode!(requested))
      assert :ok = MultiAgent.resolve_interaction(runtime, pending.correlation, "allow")
      assert_receive {:codex_collaboration, %{type: :interaction_resolved} = resolved}, 1_000
      assert resolved.manager_id == requested.manager_id
      assert resolved.interaction_id == pending.id
      assert resolved.revision > requested.revision
      assert resolved.agent.pending_interaction == nil
      assert record(runtime, child.name).pending_interaction == nil
      assert is_binary(JSON.encode!(resolved))
    end
  end

  test "public cancellation settles a preparation interaction without dispatching its backend" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(child.hook)
    correlation = requested.agent.pending_interaction.correlation
    reason = String.duplicate("é", 512)

    assert :ok = MultiAgent.cancel_interaction(runtime, correlation, reason)
    assert_receive {:codex_collaboration, %{type: :interrupted} = interrupted}, 1_000
    assert interrupted.interaction_id == correlation.interaction_id
    assert interrupted.reason == reason
    assert interrupted.agent.pending_interaction == nil
    retained = record(runtime, child.name)
    assert retained.status == :interrupted
    assert retained.pending_interaction == nil

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(runtime, correlation, "Duplicate cancellation")

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.resolve_interaction(runtime, correlation, true)

    refute_receive {:backend, _}, 20
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
  end

  test "cancellation validates every correlation field and reason before delivery" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(child.hook)
    correlation = requested.agent.pending_interaction.correlation

    for invalid <- [
          nil,
          %{},
          Map.delete(correlation, :incarnation),
          Map.put(correlation, :extra, true),
          %{correlation | incarnation: 0},
          %{correlation | interaction_id: <<255>>}
        ] do
      assert {:error, %Error{class: :validation}} =
               MultiAgent.cancel_interaction(runtime, invalid, "Cancel")
    end

    for {key, value} <- [
          manager_id: "other-manager",
          run_id: "other-run",
          incarnation: correlation.incarnation + 1,
          interaction_id: "other-interaction"
        ] do
      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.cancel_interaction(runtime, Map.put(correlation, key, value), "Cancel")
    end

    assert {:error, %Error{class: :not_found}} =
             MultiAgent.cancel_interaction(
               runtime,
               %{correlation | agent_id: "missing"},
               "Cancel"
             )

    for reason <- [nil, "", " \n\t", <<255>>, String.duplicate("é", 513), :cancelled, %{}] do
      assert {:error, %Error{class: :validation}} =
               MultiAgent.cancel_interaction(runtime, correlation, reason)
    end

    assert record(runtime, child.name).pending_interaction == requested.agent.pending_interaction
    assert :ok = MultiAgent.resolve_interaction(runtime, correlation, true)
    assert_receive {:preparation_answer, {:ok, true}}, 1_000
    assert_receive {:backend, _}, 1_000
  end

  test "cancellation waits for terminal store acknowledgement and keeps the manager responsive" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(child.hook)
    correlation = requested.agent.pending_interaction.correlation
    :ets.insert(gates, {:cancellation, true})

    cancellation =
      Task.async(fn -> MultiAgent.cancel_interaction(runtime, correlation, "Cancel") end)

    assert_receive {:cancellation_checkpoint, store}, 1_000

    try do
      assert Task.yield(cancellation, 20) == nil
      assert {:ok, _} = MultiAgent.snapshot(runtime)
      other = spawn_child(runtime, "during_cancellation")
      assert record(runtime, other.name).status == :running

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.cancel_interaction(runtime, correlation, "Duplicate")

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.resolve_interaction(runtime, correlation, true)
    after
      send(store, :ack)
    end

    assert :ok = Task.await(cancellation)
    [{{:store, _}, table}] = :ets.lookup(gates, {:store, child.run_id})
    assert {:ok, %{run: persisted}} = EphemeralStore.load(table, child.run_id)
    assert persisted.state == :cancelled
    assert persisted.context.conversation.pending_interaction == nil
    assert record(runtime, child.name).pending_interaction == nil
    refute_receive {:backend, _}, 20
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
  end

  test "an answer reserved before cancellation remains the only submitted operation" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    correlation = requested.agent.pending_interaction.correlation
    :ets.insert(gates, {:resolution, true})
    answer = Task.async(fn -> MultiAgent.resolve_interaction(runtime, correlation, true) end)
    assert_receive {:resolution_checkpoint, store}, 1_000

    try do
      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.cancel_interaction(runtime, correlation, "Too late")
    after
      send(store, :ack)
    end

    assert :ok = Task.await(answer)
    assert_receive {:backend_answer, {:ok, true}}, 1_000
    assert record(runtime, child.name).status == :running
    refute_receive {:codex_collaboration, %{type: :interrupted}}, 20
  end

  test "the child rejects a stale manager projection without cancelling a newer interaction" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    worker = backend(child)
    first = ask(worker)

    assert :ok =
             MultiAgent.resolve_interaction(
               runtime,
               first.agent.pending_interaction.correlation,
               true
             )

    assert_receive {:backend_answer, {:ok, true}}, 1_000
    second = ask(worker, %{kind: :second})
    child_pid = :sys.get_state(runtime).agents[child.name].pid

    :sys.replace_state(runtime, fn state ->
      state
      |> put_in([:agents, child.name, :pending_interaction], first.agent.pending_interaction)
      |> put_in([:agents, child.name, :interaction_resolution_id], nil)
      |> update_in(
        [:agents, child.name, :interaction_ids],
        &MapSet.delete(&1, second.interaction_id)
      )
    end)

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(
               runtime,
               first.agent.pending_interaction.correlation,
               "Stale cancellation"
             )

    actual = Conversation.status(child_pid)
    assert actual.phase == :waiting_interaction
    assert actual.conversation.pending_interaction.id == second.interaction_id
    refute :sys.get_state(runtime).agents[child.name].interaction_closed

    send(
      runtime,
      {:agent_runtime, child.run_id,
       %{
         type: :interaction_requested,
         incarnation: second.agent.incarnation,
         interaction_id: second.interaction_id,
         request: second.agent.pending_interaction.request
       }}
    )

    assert record(runtime, child.name).pending_interaction == second.agent.pending_interaction

    assert :ok =
             MultiAgent.resolve_interaction(
               runtime,
               second.agent.pending_interaction.correlation,
               true
             )

    assert_receive {:backend_answer, {:ok, true}}, 1_000
  end

  for failure <- [:store_failure, :lost_ack, :terminal_ack_lost, :worker_down, :timeout] do
    test "cancellation #{failure} remains uncertain and never retries" do
      {runtime, gates} = start_runtime(2)
      child = spawn_child(runtime)
      requested = ask(child.hook)
      correlation = requested.agent.pending_interaction.correlation
      :ets.insert(gates, {:cancellation, true})

      cancellation =
        Task.async(fn -> MultiAgent.cancel_interaction(runtime, correlation, "Cancel") end)

      assert_receive {:cancellation_checkpoint, store}, 1_000
      [{token, settlement}] = Map.to_list(:sys.get_state(runtime).settlements)

      try do
        case unquote(failure) do
          :store_failure ->
            send(store, :fail)

          :lost_ack ->
            send(store, :lose_ack)
            [{{:store, _}, table}] = :ets.lookup(gates, {:store, child.run_id})

            assert eventually(fn ->
                     match?(
                       {:ok, %{run: %{state: :cancelled}}},
                       EphemeralStore.load(table, child.run_id)
                     )
                   end)

            send(runtime, {:settlement_timeout, token})

          :terminal_ack_lost ->
            assert :erlang.suspend_process(settlement.worker)
            send(store, :ack)

            assert eventually(fn ->
                     Conversation.status(settlement.pins[child.name].pid).phase == :terminal
                   end)

            send(runtime, {:settlement_timeout, token})

          :worker_down ->
            Process.exit(settlement.worker, :kill)

          :timeout ->
            send(runtime, {:settlement_timeout, token})
        end

        assert {:error, %Error{class: :unknown_outcome}} = Task.await(cancellation)

        assert {:error, %Error{class: :resource_conflict}} =
                 MultiAgent.cancel_interaction(runtime, correlation, "Do not retry")

        assert {:error, %Error{class: :resource_conflict}} =
                 MultiAgent.resolve_interaction(runtime, correlation, true)

        assert record(runtime, child.name).cleanup == :uncertain

        assert {:error, %Error{class: :resource_conflict}} =
                 call(runtime, "spawn_agent", %{"task_name" => "blocked", "message" => "work"})

        refute_receive {:cancellation_checkpoint, _}, 20
        refute_receive {:backend, _}, 20
        refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
      after
        send(store, :ack)
      end
    end
  end

  test "backend cancellation retains uncertain execution capacity while siblings continue" do
    {runtime, _} = start_runtime(3)
    child = spawn_child(runtime)
    requested = ask(backend(child))
    sibling = spawn_child(runtime, "sibling")

    assert {:error, %Error{class: :unknown_outcome}} =
             MultiAgent.cancel_interaction(
               runtime,
               requested.agent.pending_interaction.correlation,
               "Cancel"
             )

    assert record(runtime, child.name).pending_interaction == nil
    assert record(runtime, child.name).cleanup == :uncertain
    assert record(runtime, sibling.name).status == :running

    assert {:error, %Error{class: :resource_conflict}} =
             call(runtime, "spawn_agent", %{"task_name" => "blocked", "message" => "work"})

    send(sibling.hook, :allow)
    assert_receive {:backend, _}, 1_000
  end

  test "old cancellation correlations reject replacements while historical interrupt targets current work" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(child.hook)

    assert :ok =
             MultiAgent.cancel_interaction(
               runtime,
               requested.agent.pending_interaction.correlation,
               "Cancel"
             )

    assert {:ok, _} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "Again"})

    assert_receive {:child_options, replacement_run_id, _}, 1_000
    assert replacement_run_id != child.run_id
    assert_receive {:provider, %{run_id: ^replacement_run_id}, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "question", name: "question", arguments: %{}}
         },
         %{type: :response_completed, message: %{role: :assistant, content: "asking"}}
       ]}
    )

    assert_receive {:preparation, hook}, 1_000
    replacement = ask(hook)

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(
               runtime,
               requested.agent.pending_interaction.correlation,
               "Stale"
             )

    assert record(runtime, child.name).pending_interaction ==
             replacement.agent.pending_interaction

    assert {:ok, %{status: :interrupted}} =
             call(runtime, "interrupt_agent", %{"target" => child.run_id})

    assert record(runtime, child.name).run_id == replacement_run_id
    assert record(runtime, child.name).pending_interaction == nil
    refute_receive {:backend, _}, 20
  end

  for shutdown <- [:normal, :kill] do
    test "manager #{shutdown} exit stops its held cancellation worker" do
      {runtime, gates} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(child.hook)
      :ets.insert(gates, {:cancellation, true})

      cancellation =
        Task.async(fn ->
          try do
            MultiAgent.cancel_interaction(
              runtime,
              requested.agent.pending_interaction.correlation,
              "Cancel"
            )
          catch
            :exit, _ -> :manager_stopped
          end
        end)

      assert_receive {:cancellation_checkpoint, _store}, 1_000
      [{_token, settlement}] = Map.to_list(:sys.get_state(runtime).settlements)
      supervisor = :sys.get_state(runtime).child_supervisor
      monitor = Process.monitor(settlement.worker)

      assert Enum.any?(DynamicSupervisor.which_children(supervisor), fn {_, pid, _, _} ->
               pid == settlement.worker
             end)

      if unquote(shutdown) == :normal do
        assert :ok = GenServer.stop(runtime, :normal)
        assert {:error, %Error{class: :unknown_outcome}} = Task.await(cancellation)
      else
        Process.exit(runtime, :kill)
        assert :manager_stopped = Task.await(cancellation)
      end

      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      refute Process.alive?(settlement.worker)
      assert eventually(fn -> not Process.alive?(supervisor) end)
    end
  end

  test "atomic resubscription includes actionable pending and revision watermark" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    assert :ok = MultiAgent.unsubscribe(runtime)
    assert {:ok, snapshot} = MultiAgent.subscribe(runtime)
    assert snapshot.manager_id == requested.manager_id
    assert snapshot.revision >= requested.revision
    assert hd(snapshot.agents).pending_interaction == requested.agent.pending_interaction
    assert is_binary(JSON.encode!(snapshot))

    assert :ok =
             MultiAgent.resolve_interaction(
               runtime,
               hd(snapshot.agents).pending_interaction.correlation,
               true
             )
  end

  test "full correlation and JSON-safe values are validated before child delivery" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    correlation = requested.agent.pending_interaction.correlation

    for invalid <- [
          nil,
          %{},
          Map.delete(correlation, :incarnation),
          Map.put(correlation, :extra, true)
        ] do
      assert {:error, %Error{class: :validation}} =
               MultiAgent.resolve_interaction(runtime, invalid, true)
    end

    for {key, value} <- [
          manager_id: "other",
          run_id: "other",
          incarnation: 99,
          interaction_id: "other"
        ] do
      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.resolve_interaction(runtime, Map.put(correlation, key, value), true)
    end

    assert {:error, %Error{class: :not_found}} =
             MultiAgent.resolve_interaction(runtime, %{correlation | agent_id: "missing"}, true)

    for value <- [self(), make_ref(), fn -> :opaque end, {"tuple", 1}] do
      assert {:error, %Error{class: :validation}} =
               MultiAgent.resolve_interaction(runtime, correlation, value)
    end

    assert record(runtime, child.name).pending_interaction == requested.agent.pending_interaction
    assert :ok = MultiAgent.resolve_interaction(runtime, correlation, true)

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.resolve_interaction(runtime, correlation, true)
  end

  test "a held checkpoint reserves duplicates and leaves snapshot and unrelated child responsive" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    correlation = requested.agent.pending_interaction.correlation
    :ets.insert(gates, {:resolution, true})
    answer = Task.async(fn -> MultiAgent.resolve_interaction(runtime, correlation, "allow") end)
    assert_receive {:resolution_checkpoint, store}, 1_000
    assert Task.yield(answer, 20) == nil
    assert record(runtime, child.name).pending_interaction != nil

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.resolve_interaction(runtime, correlation, "allow")

    other = spawn_child(runtime, "other")
    assert record(runtime, other.name).status == :running
    refute_receive {:backend_answer, _}, 20
    send(store, :ack)
    assert :ok = Task.await(answer)
    assert_receive {:backend_answer, {:ok, "allow"}}, 1_000
  end

  test "interrupt clears pending and cancels held resolution without publishing resolved" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    correlation = requested.agent.pending_interaction.correlation
    :ets.insert(gates, {:resolution, true})
    answer = Task.async(fn -> MultiAgent.resolve_interaction(runtime, correlation, true) end)
    assert_receive {:resolution_checkpoint, store}, 1_000
    interrupt = Task.async(fn -> call(runtime, "interrupt_agent", %{"target" => child.name}) end)
    assert {:error, %Error{}} = Task.await(answer)

    try do
      probe = Task.async(fn -> MultiAgent.snapshot(runtime) end)
      assert {:ok, {:ok, snapshot}} = Task.yield(probe, 1_000)
      assert Enum.find(snapshot.agents, &(&1.name == child.name)).pending_interaction == nil
      other = spawn_child(runtime, "during_interrupt")
      assert record(runtime, other.name).status == :running
    after
      send(store, :ack)
    end

    assert {:error, %Error{class: :unknown_outcome}} = Task.await(interrupt)
    assert record(runtime, child.name).pending_interaction == nil

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.resolve_interaction(runtime, correlation, true)

    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 30
    refute_receive {:backend_answer, {:ok, _}}, 30
  end

  for close <- [:child, :session] do
    test "#{close} close leaves the manager responsive while resolution storage is held" do
      {runtime, gates} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(backend(child))
      correlation = requested.agent.pending_interaction.correlation
      :ets.insert(gates, {:resolution, true})
      answer = Task.async(fn -> MultiAgent.resolve_interaction(runtime, correlation, true) end)
      assert_receive {:resolution_checkpoint, store}, 1_000

      closing =
        Task.async(fn ->
          if unquote(close) == :session,
            do: MultiAgent.close_session(runtime),
            else: call(runtime, "multi_agent_v1::close_agent", %{"target" => child.run_id}, :v1)
        end)

      assert {:error, %Error{}} = Task.await(answer)

      try do
        probe = Task.async(fn -> MultiAgent.snapshot(runtime) end)
        assert {:ok, {:ok, snapshot}} = Task.yield(probe, 1_000)
        assert Enum.find(snapshot.agents, &(&1.name == child.name)).pending_interaction == nil

        if unquote(close) == :child do
          other = spawn_child(runtime, "during_close")
          assert record(runtime, other.name).status == :running
        end
      after
        send(store, :ack)
      end

      if unquote(close) == :session,
        do: assert(:ok = Task.await(closing)),
        else: assert({:ok, %{status: :shutdown}} = Task.await(closing))

      refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
      refute_receive {:backend_answer, {:ok, _}}, 20
    end
  end

  for close <- [:child, :session] do
    test "queued #{close} close prevents an admitted interrupting input from replacing the child" do
      {runtime, gates} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(backend(child))
      :ets.insert(gates, {:resolution, true})

      answer =
        Task.async(fn ->
          MultiAgent.resolve_interaction(
            runtime,
            requested.agent.pending_interaction.correlation,
            true
          )
        end)

      assert_receive {:resolution_checkpoint, store}, 1_000

      input =
        Task.async(fn ->
          call(
            runtime,
            "multi_agent_v1::send_input",
            %{
              "target" => child.run_id,
              "message" => "replace this turn",
              "interrupt" => true
            },
            :v1
          )
        end)

      assert {:error, %Error{}} = Task.await(answer)

      closing =
        Task.async(fn ->
          if unquote(close) == :session,
            do: MultiAgent.close_session(runtime),
            else: call(runtime, "multi_agent_v1::close_agent", %{"target" => child.run_id}, :v1)
        end)

      try do
        assert eventually(fn -> length(:sys.get_state(runtime).settlement_queue) == 1 end)
        assert record(runtime, child.name).pending_interaction == nil
      after
        send(store, :ack)
      end

      assert {:error, %Error{class: :resource_conflict}} = Task.await(input)

      if unquote(close) == :session,
        do: assert(:ok = Task.await(closing)),
        else: assert({:ok, %{status: :shutdown}} = Task.await(closing))

      retained = record(runtime, child.name)
      assert retained.run_id == child.run_id
      assert retained.incarnation == requested.agent.incarnation
      assert retained.pending_interaction == nil
      refute_receive {:child_options, _, _}, 20
      refute_receive {:provider, _, _}, 20
      refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
    end
  end

  for close <- [:child, :session] do
    test "#{close} close fences public resolution" do
      {runtime, _} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(backend(child))
      correlation = requested.agent.pending_interaction.correlation

      if unquote(close) == :session do
        assert :ok = MultiAgent.close_session(runtime)
      else
        assert {:ok, _} =
                 call(runtime, "multi_agent_v1::close_agent", %{"target" => child.run_id}, :v1)
      end

      assert record(runtime, child.name).pending_interaction == nil

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.resolve_interaction(runtime, correlation, true)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.cancel_interaction(runtime, correlation, "Already closed")

      refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
    end
  end

  test "persistence failure clears actionable pending without a success acknowledgement" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    :ets.insert(gates, {:resolution, true})

    answer =
      Task.async(fn ->
        MultiAgent.resolve_interaction(
          runtime,
          requested.agent.pending_interaction.correlation,
          true
        )
      end)

    assert_receive {:resolution_checkpoint, store}, 1_000
    send(store, :fail)
    assert {:error, %Error{}} = Task.await(answer)
    assert eventually(fn -> record(runtime, child.name).pending_interaction == nil end)
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
    refute_receive {:backend_answer, {:ok, _}}, 20
  end

  test "child exit rejects a held answer as unknown outcome and never retries" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    requested = ask(backend(child))
    :ets.insert(gates, {:resolution, true})

    answer =
      Task.async(fn ->
        MultiAgent.resolve_interaction(
          runtime,
          requested.agent.pending_interaction.correlation,
          true
        )
      end)

    assert_receive {:resolution_checkpoint, _store}, 1_000
    child_pid = :sys.get_state(runtime).agents[child.name].pid
    Process.exit(child_pid, :kill)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(answer)
    assert eventually(fn -> record(runtime, child.name).pending_interaction == nil end)
    refute_receive {:resolution_checkpoint, _}, 30
  end

  test "child exit fences a held settlement worker without releasing execution capacity" do
    {runtime, gates} = start_runtime(2)
    child = spawn_child(runtime)
    requested = ask(backend(child))
    :ets.insert(gates, {:resolution, true})

    answer =
      Task.async(fn ->
        MultiAgent.resolve_interaction(
          runtime,
          requested.agent.pending_interaction.correlation,
          true
        )
      end)

    assert_receive {:resolution_checkpoint, store}, 1_000
    interrupt = Task.async(fn -> call(runtime, "interrupt_agent", %{"target" => child.name}) end)
    assert {:error, %Error{}} = Task.await(answer)
    [{_token, settlement}] = Map.to_list(:sys.get_state(runtime).settlements)
    assert :erlang.suspend_process(settlement.worker)

    try do
      Process.exit(settlement.pins[child.name].pid, :kill)
      assert_receive {:codex_collaboration, %{type: :process_exited, agent: exited}}, 1_000
      assert exited.run_id == child.run_id
      assert exited.status == :unknown_outcome
      assert exited.pending_interaction == nil
    after
      send(store, :ack)
      :erlang.resume_process(settlement.worker)
    end

    assert {:error, %Error{class: :unknown_outcome}} = Task.await(interrupt)
    assert :sys.get_state(runtime).settlements == %{}
    retained = record(runtime, child.name)
    assert retained.run_id == child.run_id
    assert retained.status == :unknown_outcome
    assert retained.cleanup == :uncertain
    assert retained.pending_interaction == nil

    assert {:error, %Error{class: :resource_conflict}} =
             call(runtime, "spawn_agent", %{"task_name" => "blocked", "message" => "work"})

    refute_receive {:child_options, _, _}, 20
    refute_receive {:provider, _, _}, 20
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 20
  end

  for failure <- [:worker_down, :timeout] do
    test "settlement #{failure} retains uncertainty and its execution reservation" do
      {runtime, gates} = start_runtime(2)
      child = spawn_child(runtime)
      requested = ask(backend(child))
      :ets.insert(gates, {:resolution, true})

      answer =
        Task.async(fn ->
          MultiAgent.resolve_interaction(
            runtime,
            requested.agent.pending_interaction.correlation,
            true
          )
        end)

      assert_receive {:resolution_checkpoint, store}, 1_000

      interrupt =
        Task.async(fn -> call(runtime, "interrupt_agent", %{"target" => child.name}) end)

      assert {:error, %Error{}} = Task.await(answer)
      [{token, settlement}] = Map.to_list(:sys.get_state(runtime).settlements)

      try do
        if unquote(failure) == :worker_down,
          do: Process.exit(settlement.worker, :kill),
          else: send(runtime, {:settlement_timeout, token})

        assert {:error, %Error{class: :unknown_outcome}} = Task.await(interrupt)
        retained = record(runtime, child.name)
        assert retained.status == :unknown_outcome
        assert retained.cleanup == :uncertain
        assert retained.pending_interaction == nil

        assert {:error, %Error{class: :resource_conflict}} =
                 call(runtime, "spawn_agent", %{"task_name" => "blocked", "message" => "work"})

        assert {:error, %Error{class: :resource_conflict}} =
                 MultiAgent.resolve_interaction(
                   runtime,
                   requested.agent.pending_interaction.correlation,
                   true
                 )

        refute_receive {:child_options, _, _}, 20
        refute_receive {:provider, _, _}, 20
      after
        send(store, :ack)
      end
    end
  end

  test "late resolved event cannot clear a newer interaction or a replacement" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    worker = backend(child)
    first = ask(worker)
    correlation = first.agent.pending_interaction.correlation
    assert :ok = MultiAgent.resolve_interaction(runtime, correlation, true)
    assert_receive {:backend_answer, {:ok, true}}
    second = ask(worker, %{kind: :second})

    send(
      runtime,
      {:agent_runtime, child.run_id,
       %{type: :interaction_resolved, incarnation: 1, interaction_id: correlation.interaction_id}}
    )

    assert record(runtime, child.name).pending_interaction == second.agent.pending_interaction

    assert :ok =
             MultiAgent.resolve_interaction(
               runtime,
               second.agent.pending_interaction.correlation,
               true
             )

    assert_receive {:backend_answer, {:ok, true}}
    send(worker, :finish)
    assert_receive {:provider, %{run_id: run_id}, provider}, 1_000
    assert run_id == child.run_id

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert eventually(fn -> record(runtime, child.name).status == :completed end)

    assert {:ok, _} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "again"})

    replacement = record(runtime, child.name)
    assert replacement.agent_id == first.agent.agent_id
    assert replacement.run_id != child.run_id
    assert replacement.incarnation == 2
    assert replacement.pending_interaction == nil

    send(
      runtime,
      {:agent_runtime, child.run_id,
       %{
         type: :interaction_requested,
         incarnation: 1,
         interaction_id: "late",
         request: %{kind: :late}
       }}
    )

    assert record(runtime, child.name).pending_interaction == nil

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.resolve_interaction(runtime, correlation, true)
  end

  test "a delayed delivery acknowledgement cannot clear the next pending interaction" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    worker = backend(child)
    first = ask(worker)
    :ets.insert(gates, {:resolution, true})

    answer =
      Task.async(fn ->
        MultiAgent.resolve_interaction(runtime, first.agent.pending_interaction.correlation, true)
      end)

    assert_receive {:resolution_checkpoint, store}, 1_000
    [{_token, delivery}] = Map.to_list(:sys.get_state(runtime).interaction_deliveries)
    assert :erlang.suspend_process(delivery.worker)
    send(store, :ack)
    assert_receive {:backend_answer, {:ok, true}}, 1_000
    assert_receive {:codex_collaboration, %{type: :interaction_resolved}}, 1_000
    second = ask(worker, %{kind: :second})
    assert :erlang.resume_process(delivery.worker)
    assert :ok = Task.await(answer)
    assert record(runtime, child.name).pending_interaction == second.agent.pending_interaction
  end

  for failure <- [:worker_down, :timeout] do
    test "#{failure} returns unknown outcome and reserves the answer against retries" do
      {runtime, gates} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(backend(child))
      correlation = requested.agent.pending_interaction.correlation
      :ets.insert(gates, {:resolution, true})
      answer = Task.async(fn -> MultiAgent.resolve_interaction(runtime, correlation, true) end)
      assert_receive {:resolution_checkpoint, store}, 1_000
      [{token, delivery}] = Map.to_list(:sys.get_state(runtime).interaction_deliveries)

      if unquote(failure) == :worker_down do
        Process.exit(delivery.worker, :kill)
      else
        send(runtime, {:interaction_delivery_timeout, token})
      end

      assert {:error, %Error{class: :unknown_outcome}} = Task.await(answer)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.resolve_interaction(runtime, correlation, true)

      assert :sys.get_state(runtime).interaction_deliveries == %{}
      refute_receive {:resolution_checkpoint, _}, 20
      send(store, :ack)
      assert_receive {:backend_answer, {:ok, true}}, 1_000
      assert_receive {:codex_collaboration, %{type: :interaction_resolved}}, 1_000
      assert record(runtime, child.name).pending_interaction == nil
    end
  end

  test "replacement carries acknowledged host feedback with its original identity" do
    {runtime, _} = start_runtime()
    child = spawn_child(runtime)
    worker = backend(child)

    send(
      worker,
      {:feedback, %{id: "history", text: "Retain this", source: "host", stage: "PostToolUse"}}
    )

    assert_receive {:feedback_answer, {:ok, _receipt}}, 1_000
    send(worker, :finish)
    assert_receive {:provider, %{run_id: run_id}, provider}, 1_000
    assert run_id == child.run_id

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    original = :sys.get_state(runtime).agents[child.name].snapshot.conversation.host_feedback
    assert length(original) == 1

    assert {:ok, _} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "continue"})

    assert_receive {:provider, request, _provider}, 1_000
    replacement_pid = :sys.get_state(runtime).agents[child.name].pid
    replacement = Backplane.AgentRuntime.Conversation.status(replacement_pid)
    assert replacement.conversation.host_feedback == original
    assert request.run_id != child.run_id
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 1
    assert is_binary(JSON.encode!(replacement.conversation.host_feedback))
  end

  test "a committed resolution succeeds when terminal settlement overtakes the delivery acknowledgement" do
    {runtime, gates} = start_runtime()
    child = spawn_child(runtime)
    worker = backend(child)
    requested = ask(worker)
    :ets.insert(gates, {:resolution, true})

    answer =
      Task.async(fn ->
        MultiAgent.resolve_interaction(
          runtime,
          requested.agent.pending_interaction.correlation,
          true
        )
      end)

    assert_receive {:resolution_checkpoint, store}, 1_000
    [{_token, delivery}] = Map.to_list(:sys.get_state(runtime).interaction_deliveries)
    assert :erlang.suspend_process(delivery.worker)
    send(store, :ack)
    assert_receive {:backend_answer, {:ok, true}}, 1_000
    assert_receive {:codex_collaboration, %{type: :interaction_resolved}}, 1_000
    send(worker, :finish)
    assert_receive {:provider, %{run_id: run_id}, provider}, 1_000
    assert run_id == child.run_id

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert eventually(fn -> record(runtime, child.name).status == :completed end)
    assert :ok = Task.await(answer)
    refute Process.alive?(delivery.worker)
    assert record(runtime, child.name).pending_interaction == nil
    assert :sys.get_state(runtime).interaction_deliveries == %{}
  end

  for shutdown <- [:normal, :kill] do
    test "manager #{shutdown} exit stops its held delivery worker" do
      {runtime, gates} = start_runtime()
      child = spawn_child(runtime)
      requested = ask(backend(child))
      :ets.insert(gates, {:resolution, true})

      answer =
        Task.async(fn ->
          try do
            MultiAgent.resolve_interaction(
              runtime,
              requested.agent.pending_interaction.correlation,
              true
            )
          catch
            :exit, _ -> :manager_stopped
          end
        end)

      assert_receive {:resolution_checkpoint, _store}, 1_000
      [{_token, delivery}] = Map.to_list(:sys.get_state(runtime).interaction_deliveries)
      supervisor = :sys.get_state(runtime).child_supervisor

      assert Enum.any?(DynamicSupervisor.which_children(supervisor), fn {_, pid, _, _} ->
               pid == delivery.worker
             end)

      monitor = Process.monitor(delivery.worker)

      if unquote(shutdown) == :normal do
        assert :ok = GenServer.stop(runtime, :normal)
        assert {:error, %Error{class: :unknown_outcome}} = Task.await(answer)
      else
        Process.exit(runtime, :kill)
        assert :manager_stopped = Task.await(answer)
      end

      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      refute Process.alive?(delivery.worker)
      assert eventually(fn -> not Process.alive?(supervisor) end)
    end
  end
end
