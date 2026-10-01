defmodule Backplane.AgentRuntime.ConversationUncertainEffectsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

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

  defmodule Outer do
    def execute(operation) do
      context = operation.backend_context
      outer = self()

      # A supervised backend continuation can outlive the runtime's Task. Keep
      # its catch observable even when stop kills that Task immediately.
      {:ok, _} =
        Task.Supervisor.start_child(context.continuations, fn ->
          result = context.nested_dispatch.(%{tool_name: "effect", arguments: %{}})
          success = {:ok, %{text: "outer handled nested result"}}
          send(context.test, {:outer_handled, result})
          send(context.test, {:outer_attempted_success, success})
          send(outer, {:handled, success})
        end)

      receive do
        {:handled, success} -> success
      end
    end
  end

  defmodule ReadOnly do
    def execute(operation) do
      send(operation.backend_context.test, {:read_only_started, self()})
      receive do: ({:result, result} -> result)
    end
  end

  defmodule Effect do
    def execute(operation) do
      context = operation.backend_context
      File.write!(context.marker, "x", [:append])
      send(context.test, {:marker_written, self()})

      receive do
        {:result, result} -> result
      end
    end
  end

  defmodule BarrierStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, record, meta) do
      if elem(meta.command, 0) == :cleanup_settled and
           :ets.member(context.gates, :cleanup_settled) do
        :ets.delete(context.gates, :cleanup_settled)
        send(context.test, {:settlement_barrier, self()})

        receive do
          :ack ->
            EphemeralStore.store(context.table, record, meta)

          :lose_ack ->
            {:ok, _} = EphemeralStore.store(context.table, record, meta)
            receive do: (:never -> :ok)
        end
      else
        EphemeralStore.store(context.table, record, meta)
      end
    end
  end

  @tag :tmp_dir
  test "nested mutation that wrote a marker then crashed remains unresolved", %{tmp_dir: dir} do
    {pid, table, marker, _gates} = start(dir)
    worker = begin_nested(pid)
    Process.exit(worker, :kill)
    assert_receive {:outer_handled, {:error, %Error{class: :execution_failure}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, _}}, 1_000
    assert_uncertain(pid, table, marker)
  end

  @tag :tmp_dir
  test "nested mutation runtime timeout retains the invocation", %{tmp_dir: dir} do
    {pid, table, marker, _gates} = start(dir, effect_timeout: 250)
    worker = begin_nested(pid)
    state = :sys.get_state(pid)
    monitor = Process.monitor(worker)
    # The older outer deadline otherwise wins first. Isolate the nested timer
    # without replacing it or synthesizing its timeout message.
    assert Process.cancel_timer(state.effect.timer) != false
    assert Process.read_timer(state.nested.timer) > 0
    assert_receive {:outer_handled, {:error, %Error{class: :timeout}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, _}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert Process.read_timer(state.nested.timer) == false
    assert_uncertain(pid, table, marker)
  end

  @tag :tmp_dir
  test "explicit uncertain mutation cannot be handled into successful completion", %{tmp_dir: dir} do
    {pid, table, marker, _gates} = start(dir)
    worker = begin_nested(pid)
    send(worker, {:result, {:error, Error.new(:unknown_outcome, "result is uncertain")}})
    assert_receive {:outer_handled, {:error, %Error{class: :unknown_outcome}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, _}}, 1_000
    assert_uncertain(pid, table, marker)
  end

  @tag :tmp_dir
  test "direct mutating error retains its committed invocation", %{tmp_dir: dir} do
    {pid, table, marker, _gates} = start(dir)
    worker = begin_direct(pid)
    send(worker, {:result, {:error, Error.new(:execution_failure, "failed after writing")}})
    assert_uncertain(pid, table, marker)
  end

  @tag :tmp_dir
  test "lost uncertainty settlement acknowledgement fences further work", %{tmp_dir: dir} do
    {pid, table, marker, gates} = start(dir, commit_timeout: 150)
    worker = begin_nested(pid)
    :ets.insert(gates, {:cleanup_settled, true})
    Process.exit(worker, :kill)
    assert_receive {:settlement_barrier, commit_worker}, 1_000
    send(commit_worker, :lose_ack)
    assert_receive {:agent_runtime, _, %{type: :storage_failed}}, 1_000
    assert Conversation.status(pid).phase == :storage_failed
    assert {:error, %Error{class: :resource_conflict}} = Conversation.follow_up(pid, "continue")
    assert {:ok, %{run: run}} = EphemeralStore.load(table, Conversation.status(pid).run.run_id)
    assert run.state == :unknown_outcome
    assert map_size(run.active_tools) > 0
    assert File.read!(marker) == "x"
    refute_receive {:provider, _, _}, 20
  end

  @tag :tmp_dir
  test "handled read-only failure and observed mutating failure may finish", %{tmp_dir: dir} do
    for result <- [
          {:error, Error.new(:execution_failure, "read-only operation failed")},
          {:ok, %{is_error: true, text: "mutation reported failure"}}
        ] do
      {pid, table, marker, _gates} = start(dir, read_only: match?({:error, _}, result))
      readonly? = match?({:error, _}, result)
      worker = begin_nested(pid, readonly?)
      send(worker, {:result, result})
      assert_receive {:outer_handled, _}, 1_000
      assert_receive {:provider, _, provider}, 1_000
      send(provider, {:events, [done()]})
      assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000

      assert {:ok, %{run: %{state: :completed, active_tools: active}}} =
               EphemeralStore.load(table, Conversation.status(pid).run.run_id)

      assert active == %{}
      assert File.exists?(marker) == not readonly?
    end
  end

  @tag :tmp_dir
  test "successful mutation settles normally", %{tmp_dir: dir} do
    {pid, table, marker, _gates} = start(dir)
    worker = begin_nested(pid)
    send(worker, {:result, {:ok, %{text: "done"}}})
    assert_receive {:outer_handled, {:ok, _}}, 1_000
    assert_receive {:provider, _, provider}, 1_000
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000

    assert {:ok, %{run: %{state: :completed, active_tools: active}}} =
             EphemeralStore.load(table, Conversation.status(pid).run.run_id)

    assert active == %{}
    assert File.read!(marker) == "x"
  end

  @tag :tmp_dir
  test "cancellation fences a dispatched mutation and late nested and outer successes", %{
    tmp_dir: dir
  } do
    {pid, table, marker, _gates} = start(dir)
    worker = begin_nested(pid)
    state = :sys.get_state(pid)
    monitor = Process.monitor(worker)

    assert :ok = Conversation.cancel(pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:outer_handled, {:error, %Error{class: :cancelled}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, success}}, 1_000
    send(pid, {state.nested.task.ref, {:ok, [%{text: "late mutation result"}]}})
    send(pid, {state.effect.task.ref, {:ok, success}})
    assert_uncertain(pid, table, marker)
  end

  @tag :tmp_dir
  test "cancellation and outer success during uncertainty commit cannot consume the obligation",
       %{tmp_dir: dir} do
    {pid, table, marker, gates} = start(dir)
    worker = begin_nested(pid)
    outer_ref = :sys.get_state(pid).effect.task.ref
    :ets.insert(gates, {:cleanup_settled, true})
    send(worker, {:result, {:error, Error.new(:unknown_outcome, "lost result")}})
    assert_receive {:settlement_barrier, commit_worker}, 1_000
    assert_receive {:outer_handled, {:error, %Error{class: :unknown_outcome}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, success}}, 1_000
    send(pid, {outer_ref, {:ok, success}})
    assert :ok = Conversation.cancel(pid)

    assert {:ok, %{run: pending}} =
             EphemeralStore.load(table, Conversation.status(pid).run.run_id)

    assert pending.state == :cancelling

    assert Enum.any?(pending.active_tools, fn {_, invocation} ->
             invocation.tool_name == "effect"
           end)

    refute_receive {:provider, _, _}, 20
    send(commit_worker, :ack)
    assert_uncertain(pid, table, marker)
    refute_receive {:agent_runtime, _, %{type: :run_cancelled}}, 20
  end

  @tag :tmp_dir
  test "public collaboration continuation and replacement refuse unresolved mutation without replay",
       %{tmp_dir: dir} do
    {base, table, marker, _gates} = options(dir, [])
    test_pid = self()

    runtime =
      start_supervised!(
        {MultiAgent,
         [
           parent_run_id: "root",
           parent_name: "/root",
           parent_authority: %{
             caller: "host",
             run_id: "root",
             grants: ["outer", "effect"],
             tool_revision: 1
           },
           subscriber: self(),
           min_wait_timeout_ms: 0,
           child_options: fn _request, run_id, _parent ->
             send(test_pid, {:child_options, run_id})

             {:ok,
              base
              |> Keyword.put(:run_id, run_id)
              |> Keyword.update!(:authority, &Map.put(&1, :run_id, run_id))}
           end
         ]}
      )

    assert {:ok, %{agent_id: run_id}} = collab(runtime, "spawn_agent", %{"message" => "mutate"})
    assert_receive {:child_options, ^run_id}
    assert_receive {:provider, _, provider}, 1_000
    worker = dispatch_nested(provider)
    [agent] = Map.values(:sys.get_state(runtime).agents)
    Process.exit(worker, :kill)
    assert_receive {:outer_handled, {:error, %Error{class: :execution_failure}}}, 1_000
    assert_receive {:outer_attempted_success, {:ok, _}}, 1_000

    assert {:ok, _} =
             collab(runtime, "wait_agent", %{"targets" => [run_id], "timeout_ms" => 1_000})

    for interrupt? <- [false, true] do
      assert {:error, %Error{class: :unknown_outcome}} =
               collab(runtime, "send_input", %{
                 "target" => run_id,
                 "message" => "unsafe replacement",
                 "interrupt" => interrupt?
               })
    end

    assert {:ok, %{run: persisted}} = EphemeralStore.load(table, run_id)
    assert persisted.state == :unknown_outcome

    assert Enum.any?(persisted.active_tools, fn {id, invocation} ->
             invocation.tool_name == "effect" and
               persisted.execution_intents["tool:#{id}"].status == :uncertain
           end)

    assert Conversation.status(agent.pid).run.run_id == run_id
    assert File.read!(marker) == "x"
    refute_receive {:child_options, _}, 20
    refute_receive {:provider, _, _}, 20
    refute_receive {:marker_written, _}, 20
  end

  defp collab(runtime, name, arguments) do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: :v1},
      run_id: "root",
      tool_name: "multi_agent_v1::#{name}",
      arguments: arguments
    })
  end

  test "settlement trusts typed outcomes and read-only descriptors, never retry safety or error details" do
    forged =
      Error.new(:execution_failure, "read_only success confirmed",
        details: %{
          read_only: true,
          retry_safe: true,
          certainty: :confirmed
        }
      )

    assert ToolEffects.settlement({:error, forged}, %{read_only: false, retry_safe: true}) ==
             :uncertain

    assert ToolEffects.settlement({:error, forged}, %{read_only: true}) == :settled

    assert ToolEffects.settlement({:error, Error.new(:unknown_outcome, "unknown")}, %{
             read_only: true,
             retry_safe: true
           }) == :uncertain

    assert ToolEffects.settlement({:ok, %{is_error: true}}, %{read_only: false, retry_safe: false}) ==
             :settled
  end

  defp start(dir, opts \\ []) do
    {options, table, marker, gates} = options(dir, opts)
    pid = start_supervised!({Conversation, options}, id: make_ref())
    {pid, table, marker, gates}
  end

  defp options(dir, opts) do
    {:ok, table} = EphemeralStore.new(1)
    gates = :ets.new(:uncertain_effect_gates, [:set, :public])
    marker = Path.join(dir, "marker-#{System.unique_integer([:positive])}")
    run_id = Keyword.get(opts, :run_id, "uncertain-#{System.unique_integer([:positive])}")
    read_only = Keyword.get(opts, :read_only, false)
    backend = if read_only, do: ReadOnly, else: Effect
    continuations = start_supervised!(Task.Supervisor, id: make_ref())

    registry =
      Enum.reduce([{"outer", Outer, true}, {"effect", backend, read_only}], %ToolRegistry{}, fn
        {name, backend, safety}, registry ->
          {:ok, registry} =
            ToolRegistry.register(registry, %{
              tool_name: name,
              tool_revision: 1,
              description: name,
              schema: %{"type" => "object", "properties" => %{}},
              safety: %{read_only: safety, retry_safe: safety, parallel_safe: false},
              backend: backend,
              backend_context: %{test: self(), marker: marker, continuations: continuations}
            })

          registry
      end)

    options = [
      run_id: run_id,
      incarnation: 1,
      store: BarrierStore,
      context: %{table: table, gates: gates, test: self()},
      provider: Provider,
      provider_context: %{test: self()},
      subscriber: self(),
      registry: registry,
      authority: %{caller: "host", run_id: run_id, grants: ["outer", "effect"], tool_revision: 1},
      tools: [%{name: "outer", description: "outer", parameters: %{}}],
      work: 20,
      run_timeout: 5_000,
      effect_timeout: Keyword.get(opts, :effect_timeout, 3_000),
      commit_timeout: Keyword.get(opts, :commit_timeout, 1_000)
    ]

    {options, table, marker, gates}
  end

  defp begin_nested(pid, readonly? \\ false) do
    assert {:ok, _} = Conversation.prompt(pid, "start")
    assert_receive {:provider, _, provider}, 1_000
    dispatch_nested(provider, readonly?)
  end

  defp dispatch_nested(provider, readonly? \\ false) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: "outer", name: "outer", arguments: %{}}},
         done()
       ]}
    )

    if readonly? do
      assert_receive {:read_only_started, worker}, 1_000
      worker
    else
      assert_receive {:marker_written, worker}, 1_000
      worker
    end
  end

  defp begin_direct(pid) do
    assert {:ok, _} = Conversation.prompt(pid, "start")
    assert_receive {:provider, _, provider}, 1_000

    send(provider, {
      :events,
      [
        %{type: :tool_call_completed, tool_call: %{id: "direct", name: "effect", arguments: %{}}},
        done()
      ]
    })

    assert_receive {:marker_written, worker}, 1_000
    worker
  end

  defp assert_uncertain(pid, table, marker) do
    assert_receive {:agent_runtime, _, %{type: :run_cancelled, state: :unknown_outcome}}, 1_000
    status = Conversation.status(pid)
    assert status.run.state == :unknown_outcome

    assert [{invocation_id, invocation}] =
             Enum.filter(status.run.active_tools, fn {_id, invocation} ->
               invocation.tool_name == "effect"
             end)

    assert invocation.tool_name == "effect"
    assert status.run.execution_intents["tool:#{invocation_id}"].status == :uncertain
    assert {:ok, %{run: persisted}} = EphemeralStore.load(table, status.run.run_id)
    assert persisted.active_tools == status.run.active_tools
    assert persisted.execution_intents["tool:#{invocation_id}"].status == :uncertain
    assert {:error, %Error{class: :resource_conflict}} = Conversation.follow_up(pid, "continue")
    assert {:error, %Error{class: :resource_conflict}} = Conversation.prompt(pid, "replacement")
    assert File.read!(marker) == "x"
    refute_receive {:provider, _, _}, 20
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
