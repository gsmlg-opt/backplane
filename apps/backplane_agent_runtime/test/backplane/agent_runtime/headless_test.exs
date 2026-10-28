defmodule Backplane.AgentRuntime.HeadlessTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
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

  @tag :host_context
  test "trusted host context reaches original hooks without a provider and respects Store ACKs" do
    run = "headless-host-context"
    {opts, store} = options(run, echo_backend: __MODULE__.HostEcho)
    test = self()

    resolver = fn invocation, catalog ->
      send(test, {:host_resolver, invocation, catalog})
      %{test: test, marker: "ephemeral-host-resolver"}
    end

    host_context = %{
      tool_context_resolver: resolver,
      host_metadata: "ephemeral-host-metadata",
      catalog_snapshot: :host_cannot_replace_catalog,
      register_code_mode: :host_cannot_replace_runtime_callback,
      effect_deadline: :host_cannot_replace_deadline
    }

    opts =
      opts
      |> Keyword.put(:hooks, __MODULE__.ResolverHooks)
      |> Keyword.put(:host_context, host_context)
      |> Keyword.put(:context, Map.put(opts[:context], :host_gates, true))
      |> Keyword.put(:subscriber, self())

    {:ok, owner} = Headless.start_link(opts)

    assert {:ok, _} =
             Headless.execute(
               owner,
               "text('before'); const value = await tools.echo({value: input.value}); text('after'); return value;",
               input: %{value: 41}
             )

    assert_receive {:host_prepare, outer, outer_context, %{marker: "ephemeral-host-resolver"}},
                   2_000

    assert outer.tool_name == "exec"
    assert outer_context.host_metadata == "ephemeral-host-metadata"
    assert outer_context.tool_context_resolver == resolver
    assert outer_context.catalog_snapshot.registry == opts[:registry]
    assert outer_context.catalog_snapshot.authority == opts[:authority]
    refute Map.has_key?(outer_context, :register_code_mode)

    assert_receive {:host_timeout, ^outer, outer_selection}, 2_000
    assert outer_selection.catalog_snapshot == outer_context.catalog_snapshot
    assert outer_selection.invocation_id == outer.invocation_id
    assert outer_selection.tool_call_id == outer.tool_call_id
    assert_inspection_context(outer_selection)

    assert_receive {:host_prepare, nested, nested_context, %{marker: "ephemeral-host-resolver"}},
                   2_000

    assert nested.tool_name == "echo"
    assert nested.enclosing_invocation_id == outer.invocation_id
    assert nested_context.tool_context_resolver == resolver
    assert nested_context.host_metadata == outer_context.host_metadata
    assert nested_context.catalog_snapshot == outer_context.catalog_snapshot
    refute Map.has_key?(nested_context, :register_code_mode)
    assert_receive {:host_timeout, ^nested, nested_selection}, 2_000
    assert nested_selection.invocation_id == nested.invocation_id
    assert nested_selection.catalog_snapshot == outer_context.catalog_snapshot
    assert_inspection_context(nested_selection)

    assert_receive {:host_checkpoint, :tool_invoked, nested_id, intent_writer}, 2_000
    assert nested_id == nested.invocation_id
    assert {:ok, %{run: intent_record}} = EphemeralStore.load(store, run)

    assert intent_record.execution_intents["tool:#{nested_id}"].operation.invocation_id ==
             nested_id

    refute_receive {:host_effect, _, _}, 20

    binding = Keyword.fetch!(opts, :session_binding)
    {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    worker_ref = Process.monitor(worker)

    send(intent_writer, :acknowledge_host)
    assert_receive {:host_effect, operation, {:ok, %{remaining_ms: remaining}}}, 2_000
    assert operation.invocation_id == nested_id
    assert operation.backend_context.catalog_snapshot == outer_context.catalog_snapshot
    assert is_function(operation.backend_context.effect_deadline, 0)
    assert remaining > 0 and remaining <= 1_000
    assert_receive {:host_checkpoint, :tool_completed, ^nested_id, result_writer}, 2_000
    assert {:ok, %{run: result_record}} = EphemeralStore.load(store, run)
    assert Map.has_key?(result_record.tool_results, nested_id)
    assert {:error, %Error{class: :timeout}} = Headless.await(owner, timeout: 0)
    refute_receive {:agent_runtime, ^run, %{type: :tool_settled}}, 20

    send(result_writer, :acknowledge_host)
    assert {:ok, result} = Headless.await(owner, timeout: 3_000)
    assert result.value == %{"value" => 41}
    assert result.nested_invocations == 1
    assert result.output == Enum.map(["before", "after"], &%{"type" => "text", "text" => &1})
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 2_000
    assert :ok = CodeMode.Worker.cleanup_identity(os_identity)
    assert Headless.status(owner).resource_cleanup == :confirmed
    assert {:ok, %{run: record}} = EphemeralStore.load(store, run)
    assert record.state == :completed
    assert Map.get(record, :provider_attempts, %{}) == %{}
    refute JSON.encode!(record) =~ "ephemeral-host-"
    refute_receive {:headless_commit, :provider_started}, 0
    refute_receive {:host_effect, _, _}, 0
  end

  @tag :host_context
  test "host context must be a map and never permits provider options in Headless" do
    {opts, store} = options("headless-context-options")

    for invalid <- [nil, [], :host, self()] do
      assert {:error, %Error{class: :validation}} =
               Headless.start_link(Keyword.put(opts, :host_context, invalid))
    end

    for provider_option <- [[provider: __MODULE__.HookProvider], [provider_context: %{}]] do
      assert {:error, %Error{class: :validation}} =
               Headless.start_link(Keyword.merge(opts, provider_option))
    end

    assert {:error, %Error{class: :not_found}} =
             EphemeralStore.load(store, "headless-context-options")
  end

  for mode <- [:legacy, :overlay] do
    @tag :host_context
    @tag context_mode: mode
    test "#{mode} provider context remains compatible and separate from host metadata", context do
      run = "provider-host-context-#{context.context_mode}"
      {opts, _store} = options(run)
      test = self()
      resolver = fn _, _ -> %{test: test, marker: :resolved} end

      legacy = %{test: test, tool_context_resolver: resolver, host_metadata: :legacy}

      opts =
        opts
        |> Keyword.put(:provider, __MODULE__.HookProvider)
        |> Keyword.put(:provider_context, legacy)
        |> Keyword.put(:hooks, __MODULE__.ResolverHooks)

      opts =
        if context.context_mode == :overlay,
          do:
            Keyword.put(opts, :host_context, %{
              host_metadata: :host,
              host_only: "provider-must-not-see-host-data"
            }),
          else: opts

      {:ok, owner} = Conversation.start_link(opts)
      assert {:ok, _} = Conversation.prompt(owner, "echo once")
      assert_receive {:hook_provider, _request, provider_context, provider}, 2_000
      assert provider_context.host_metadata == :legacy
      assert provider_context.tool_context_resolver == resolver
      refute Map.has_key?(provider_context, :host_only)

      send(provider, {:events, [echo_call(), provider_done()]})
      assert_receive {:host_prepare, invocation, preparation, _}, 2_000
      assert invocation.tool_name == "echo"

      assert preparation.host_metadata ==
               if(context.context_mode == :legacy, do: :legacy, else: :host)

      assert preparation.tool_context_resolver == resolver
      assert_receive {:host_timeout, ^invocation, selection}, 2_000
      assert selection.host_metadata == preparation.host_metadata
      assert_inspection_context(selection)
      assert_receive {:echo_effect, _}, 2_000
      assert_receive {:hook_provider, _, next_provider_context, next_provider}, 2_000
      assert next_provider_context.host_metadata == :legacy
      refute Map.has_key?(next_provider_context, :host_only)
      send(next_provider, {:events, [provider_done()]})
      eventually_value(fn -> Conversation.status(owner).phase == :terminal end)
      assert Conversation.status(owner).run.state == :completed
    end
  end

  defp assert_inspection_context(context) do
    for capability <- [
          :interact,
          :emit,
          :provider_emit,
          :request_new_context,
          :nested_dispatch,
          :register_cancellation,
          :register_code_mode,
          :cancellation_coordinator,
          :stage_catalog,
          :append_feedback,
          :effect_deadline,
          :resource_owner_pid
        ],
        do: refute(Map.has_key?(context, capability))
  end

  defp echo_call do
    %{
      type: :tool_call_completed,
      tool_call: %{id: "host-echo", name: "echo", arguments: %{"value" => 42}}
    }
  end

  defp provider_done,
    do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

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

      if context[:host_gates] == true and
           elem(meta.command, 0) in [:tool_invoked, :tool_completed] and
           elem(meta.command, 2)[:tool_name] == "echo" do
        send(
          context.test,
          {:host_checkpoint, elem(meta.command, 0), elem(meta.command, 2).invocation_id, self()}
        )

        receive do
          :acknowledge_host -> :ok
        end
      end

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

  defmodule HostEcho do
    def execute(operation) do
      send(
        operation.backend_context.test,
        {:host_effect, operation, operation.backend_context.effect_deadline.()}
      )

      {:ok, operation.arguments}
    end
  end

  defmodule ResolverHooks do
    def prepare_tool(invocation, context) do
      resolved = context.tool_context_resolver.(invocation, context.catalog_snapshot)
      send(resolved.test, {:host_prepare, invocation, context, resolved})
      :allow
    end

    def tool_effect_timeout(invocation, context) do
      resolved = context.tool_context_resolver.(invocation, context.catalog_snapshot)
      send(resolved.test, {:host_timeout, invocation, context})
      {:ok, 1_000}
    end
  end

  defmodule HookProvider do
    def stream(request, context) do
      send(context.test, {:hook_provider, request, context, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
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
