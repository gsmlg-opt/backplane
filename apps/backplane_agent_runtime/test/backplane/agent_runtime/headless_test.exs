defmodule Backplane.AgentRuntime.HeadlessTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}

  for {label, code, expected} <- [
        {"zero", "text(input.name); yield 'slice'; text('after'); return {answer: input.value};",
         %{"answer" => 42}},
        {"nested", "return await tools.echo({value: input.value});", %{"value" => 42}}
      ] do
    @tag code: code, expected: expected, label: label
    test "native #{label} execution uses no provider and preserves raw result", context do
      run = "headless-" <> context.label
      {opts, store} = options(run)
      {:ok, owner} = apply(Headless, :start_link, [opts])

      assert {:ok, _} =
               apply(Headless, :execute, [
                 owner,
                 context.code,
                 [input: %{name: "before", value: 42}]
               ])

      assert {:ok, result} = apply(Headless, :await, [owner, [timeout: 5_000]])
      assert result.value == context.expected
      assert result.nested_invocations == if(context.label == "nested", do: 1, else: 0)
      assert result.status == :completed

      if context.label == "zero",
        do:
          assert(
            result.output == [
              %{"type" => "text", "text" => "before"},
              %{"type" => "text", "text" => "after"}
            ]
          )

      assert {:error, %Error{class: :resource_conflict}} =
               apply(Headless, :execute, [owner, "return 9;", [input: nil]])

      assert {:ok, %{run: record}} = EphemeralStore.load(store, run)
      assert record.state == :completed
      assert record.context.execution_mode == :headless
      refute_receive {:headless_commit, :provider_started}
      assert_receive {:headless_commit, :host_step_started}
      assert JSON.encode!(record.context.headless_catalog)

      assert {:error, %Error{class: :unsupported_capability}} =
               Backplane.AgentRuntime.Conversation.prompt(owner, "never call provider")

      assert apply(Headless, :status, [owner]).phase == :terminal
    end
  end

  test "await timeout and observers preserve the execute caller; owner DOWN retires real Deno" do
    {opts, _store} = options("headless-owner")
    {:ok, owner} = Headless.start_link(opts)
    test = self()

    caller =
      spawn(fn ->
        send(
          test,
          {:admission,
           Headless.execute(
             owner,
             "await new Promise(resolve => setTimeout(resolve, 10000)); return 7;"
           )}
        )

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:admission, {:ok, _}}, 1_000
    binding = Keyword.fetch!(opts, :session_binding)
    {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)

    worker =
      eventually_value(fn ->
        case DynamicSupervisor.which_children(workers) do
          [{_, pid, _, _}] -> pid
          _ -> nil
        end
      end)

    {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    assert {:error, %Error{class: :timeout}} = Headless.await(owner, timeout: 0)
    assert Headless.status(owner).phase == :running
    observer = Task.async(fn -> Headless.status(owner) end)
    assert Task.await(observer).phase == :running
    send(caller, :finish)
    eventually_value(fn -> if Headless.status(owner).phase == :terminal, do: true end)
    assert Headless.status(owner).resource_cleanup == :confirmed
    assert :ok = CodeMode.Worker.cleanup_identity(os_identity)
    refute Process.alive?(worker)
    assert {:error, _} = Headless.await(owner, timeout: 100)
  end

  test "terminal reload inspects; result ACK loss requires recovery without effect replay" do
    {opts, store} = options("headless-ack-loss")
    context = Keyword.fetch!(opts, :context) |> Map.put(:lose_on, :tool_completed)
    {:ok, owner} = Headless.start_link(Keyword.put(opts, :context, context))
    assert {:ok, _} = Headless.execute(owner, "return await tools.echo({value: 8});")
    assert_receive {:echo_effect, _}, 2_000
    assert {:error, %Error{class: :unknown_outcome}} = Headless.await(owner, timeout: 3_000)
    assert {:ok, %{run: record}} = EphemeralStore.load(store, "headless-ack-loss")
    assert map_size(record.tool_results) == 1
    restored_opts = opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, record)
    {:ok, restored} = Headless.start_link(restored_opts)
    assert Headless.status(restored).phase == :recovery_required
    assert {:error, _} = Headless.execute(restored, "return 1;")
    refute_receive {:echo_effect, _}, 50
  end

  test "automatic continuation preserves a generator arriving between a timer slice and resume" do
    {opts, store} = options("headless-slice-generator", echo_backend: __MODULE__.GatedEcho)
    context = Map.put(opts[:context], :hold_result, true)
    {:ok, owner} = Headless.start_link(Keyword.put(opts, :context, context))

    source = """
    // @exec: {"yield_time_ms": 1}
    text('before');
    const effect = await tools.echo({value: 42});
    text('between');
    yield 'generator';
    text('after');
    return effect;
    """

    assert {:ok, _} = Headless.execute(owner, source)
    assert_receive {:echo_gate, gate}, 2_000
    binding = Keyword.fetch!(opts, :session_binding)
    {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    {:ok, identity} = CodeMode.Worker.os_identity(worker)
    {caller, _} = :sys.get_state(worker).from
    assert :erlang.suspend_process(caller)

    try do
      assert {_, 0} = System.cmd("kill", ["-STOP", to_string(identity.pid)])
      send(gate, :release_echo)

      eventually_value(fn ->
        state = :sys.get_state(worker)
        state.from == nil and state.active_tool == nil
      end)

      assert {_, 0} = System.cmd("kill", ["-CONT", to_string(identity.pid)])

      eventually_value(fn ->
        state = :sys.get_state(worker)
        state.pending_yield != nil or state.terminal_result != nil
      end)

      assert {:generator, {:ok, %{value: "generator"}}} = :sys.get_state(worker).pending_yield
    after
      if Process.alive?(worker) and :sys.get_state(worker).os_cleanup_status != :ok,
        do: System.cmd("kill", ["-CONT", to_string(identity.pid)])

      :erlang.resume_process(caller)
    end

    assert_receive {:headless_result_checkpoint, writer}, 2_000
    assert {:error, %Error{class: :timeout}} = Headless.await(owner, timeout: 0)
    send(writer, :acknowledge)
    assert {:ok, result} = Headless.await(owner, timeout: 3_000)
    assert result.value == %{"value" => 42}
    assert result.nested_invocations == 1

    assert result.output ==
             Enum.map(["before", "between", "after"], &%{"type" => "text", "text" => &1})

    assert_receive {:echo_effect, _}
    refute_receive {:echo_effect, _}, 0
    refute_receive {:headless_commit, :provider_started}, 0
    assert {:ok, %{run: record}} = EphemeralStore.load(store, "headless-slice-generator")
    assert record.state == :completed
    assert map_size(record.tool_results) == 2
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
    refute Process.alive?(worker)
  end

  test "cancel after raw result checkpoint never reports successful completion" do
    {opts, _} = options("headless-cancel-result")
    context = Map.put(opts[:context], :hold_result, true)
    {:ok, owner} = Headless.start_link(Keyword.put(opts, :context, context))
    assert {:ok, _} = Headless.execute(owner, "return {ready: true};")
    assert_receive {:headless_result_checkpoint, writer}, 2_000
    assert :ok = Headless.cancel(owner)
    send(writer, :acknowledge)
    assert {:error, _} = Headless.await(owner, timeout: 3_000)
    status = Headless.status(owner)
    assert status.phase == :terminal
    assert status.run.context.conversation.headless_result.value == %{"ready" => true}
    assert status.run.state != :completed
  end

  test "truncated slices keep their prefix and share one total presentation bound" do
    {opts, _} = options("headless-truncated")
    {:ok, owner} = Headless.start_link(opts)

    source =
      "// @exec: {\"max_output_tokens\": 16}\ntext('first'); text('x'.repeat(1000)); yield 1; text('late'); return true;"

    assert {:ok, _} = Headless.execute(owner, source)
    assert {:ok, result} = Headless.await(owner)
    assert result.output == [%{"type" => "text", "text" => "first"}]
    assert result.output_truncated
  end

  test "configured Code Mode timeout is never renewed by internal yields" do
    {opts, _} = options("headless-deadline", code_timeout: 100)
    {:ok, owner} = Headless.start_link(opts)

    assert {:ok, _} =
             Headless.execute(
               owner,
               "yield 1; await new Promise(resolve => setTimeout(resolve, 400)); return 9;"
             )

    assert {:error, %Error{class: :timeout}} = Headless.await(owner, timeout: 2_000)
  end

  test "module-only source receives the same explicit JSON input" do
    {opts, _} = options("headless-module-input")
    {:ok, owner} = Headless.start_link(opts)

    assert {:ok, _} =
             Headless.execute(owner, "export {}; text(input.value);", input: %{value: "module"})

    assert {:ok, %{value: nil, output: [%{"type" => "text", "text" => "module"}]}} =
             Headless.await(owner)
  end

  test "ordinary Code Mode can declare a local input variable" do
    registry = start_supervised!(ResourceRegistry)

    assert {:ok, %{value: 1}} =
             CodeMode.execute(
               registry,
               "interactive-local-input",
               "const input = 1; return input;",
               dispatcher: fn _, _ -> {:ok, nil} end
             )
  end

  test "the complete input protocol frame is bounded before admission" do
    {opts, store} = options("headless-frame")
    {:ok, owner} = Headless.start_link(opts)
    input = String.duplicate("x", 1_048_500)

    assert {:error, %Error{class: :validation}} =
             Headless.execute(owner, "return input.length;", input: input)

    assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, "headless-frame")
  end

  test "bounded JSON validation happens before admission" do
    {opts, store} = options("headless-invalid")
    {:ok, owner} = Headless.start_link(opts)

    assert {:error, %Error{class: :validation}} =
             Headless.execute(owner, "return input;", input: self())

    assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, "headless-invalid")
    assert {:ok, _} = Headless.execute(owner, "return input;", input: nil)
    assert {:ok, %{value: nil}} = Headless.await(owner)
    {:ok, %{run: record}} = EphemeralStore.load(store, "headless-invalid")

    {:ok, restored} =
      Headless.start_link(opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, record))

    assert {:ok, %{value: nil}} = Headless.await(restored)
  end

  defp eventually_value(fun, attempts \\ 300)
  defp eventually_value(fun, 0), do: assert(fun.())

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      false ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      result ->
        result
    end
  end

  defmodule RecordingStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore
    def load(context, run, opts \\ []), do: EphemeralStore.load(context.table, run, opts)

    def store(context, run, meta) do
      result = EphemeralStore.store(context.table, run, meta)

      if context[:hold_result] == true and elem(meta.command, 0) == :conversation_updated and
           get_in(elem(meta.command, 2), [:conversation, :headless_result]) != nil and
           :ets.insert_new(context.table, {:headless_hold_once, true}) do
        send(context.test, {:headless_result_checkpoint, self()})

        receive do
          :acknowledge -> :ok
        end
      end

      if match?({:ok, _}, result),
        do: send(context.test, {:headless_commit, elem(meta.command, 0)})

      if context[:lose_on] == elem(meta.command, 0),
        do: {:error, Error.new(:unknown_outcome, "fixture lost result acknowledgement")},
        else: result
    end
  end

  defmodule Echo do
    def execute(operation) do
      send(operation.backend_context.test, {:echo_effect, operation.invocation_id})
      {:ok, operation.arguments}
    end
  end

  defmodule GatedEcho do
    def execute(operation) do
      send(operation.backend_context.test, {:echo_gate, self()})
      receive do: (:release_echo -> Echo.execute(operation))
    end
  end

  defp options(run, settings \\ []) do
    session = start_supervised!({Session, owner_pid: self()})

    authority = %{
      caller: "headless-host",
      run_id: run,
      grants: ["exec", "wait", "echo"],
      tool_revision: 1
    }

    {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    contract = %{
      name: "echo",
      description: "echo",
      schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"],
        "additionalProperties" => false
      },
      backend: Keyword.get(settings, :echo_backend, Echo),
      backend_context: %{test: self()},
      revision: 1,
      strict: true,
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{
          session_binding: binding,
          code_mode_contracts: [contract],
          timeout: Keyword.get(settings, :code_timeout, 5_000)
        },
        authority,
        tools: ["exec", "wait", "echo"]
      )

    {:ok, store} = EphemeralStore.new(1)

    {[
       run_id: run,
       incarnation: 1,
       session_binding: binding,
       registry: profile.registry,
       tools: profile.tools,
       authority: profile.authority,
       store: RecordingStore,
       context: %{table: store, test: self()},
       run_timeout: 10_000,
       effect_timeout: 8_000
     ], store}
  end
end
