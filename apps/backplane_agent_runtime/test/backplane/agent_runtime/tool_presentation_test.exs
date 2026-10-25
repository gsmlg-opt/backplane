defmodule Backplane.AgentRuntime.ToolPresentationTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, Plan, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Backend, Catalog, CodeMode, MultiAgent, Session}

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:presentation_provider, request, self()})

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

  defmodule DecoratedNative do
    def execute(operation) do
      {:ok, actual} = Backend.execute(operation)
      send(operation.backend_context.test, {:actual_effect, operation, actual})
      ToolEffects.present(operation, actual, operation.backend_context.presentation)
    end
  end

  defmodule PresentedBackend do
    def execute(operation),
      do: ToolEffects.present(operation, %{value: "actual"}, %{type: :block, text: "blocked"})
  end

  defmodule PresentedBound do
    def execute(operation) do
      {:ok, actual} = MultiAgent.call_bound(operation, operation.arguments)
      send(operation.backend_context.test, {:bound_actual_effect, operation, actual})
      ToolEffects.present(operation, actual, %{type: :stopped, text: "bound result stopped"})
    end
  end

  defmodule LostAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(ctx, run, meta) do
      result = EphemeralStore.store(ctx.table, run, meta)

      if match?({:tool_completed, _, %{presentation: _}}, meta.command) do
        send(ctx.test, :presentation_committed_without_ack)
        {:error, Error.new(:execution_failure, "lost settlement acknowledgement")}
      else
        result
      end
    end
  end

  test "actual Plan mutation commits before nested block reaches real Deno catch" do
    ctx = start(:block)
    provider = prompt(ctx)

    code = """
    try {
      const first = await tools.update_plan({plan:[{step:'first effect',status:'completed'}]});
      if (first.revision) await tools.update_plan({plan:[{step:'unwanted second effect',status:'completed'}]});
      return {branch:'success'};
    } catch (error) { return {branch:'blocked', message:error.message}; }
    """

    {request, provider} = call(provider, "exec", code)
    assert List.last(request.messages).result.value["branch"] == "blocked"
    assert List.last(request.messages).result.value["message"] =~ "host presentation"
    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    assert_receive {:actual_effect, invocation, %{revision: 2}}
    refute_receive {:actual_effect, _, _}
    assert {:ok, stored} = EphemeralStore.load(ctx.table, ctx.run)
    assert stored.run.tool_results[invocation.invocation_id].revision == 2
    assert stored.run.tool_results[invocation.invocation_id].is_error == false

    assert stored.run.tool_presentations[invocation.invocation_id].identity.enclosing_invocation_id !=
             invocation.invocation_id

    assert stored.run.active_tools == %{}
    finish(ctx, provider)
  end

  test "stopped preserves nested values while replacing outer model output after yield and wait" do
    ctx = start(:stopped)
    provider = prompt(ctx)

    code = """
    const result = await tools.update_plan({plan:[{step:'kept',status:'completed'}]});
    store('original', result.revision);
    await yield_control();
    return {original:load('original')};
    """

    {request, provider} = call(provider, "exec", "// @exec: {\"yield_time_ms\":1000}\n" <> code)
    # The accepted nested stop suppresses the model-visible yielded-cell payload.
    assert List.last(request.messages).result.stopped
    assert_receive {:actual_effect, _, %{revision: 2}}
    {:ok, stored} = EphemeralStore.load(ctx.table, ctx.run)
    yielded = stored.run.tool_results |> Map.values() |> Enum.find(&(&1[:status] == :yielded))
    assert yielded.cell_id

    {request, provider} =
      call(provider, "wait", %{"cell_id" => yielded.cell_id, "yield_time_ms" => 1000})

    assert List.last(request.messages).result.value["original"] == 2
    finish(ctx, provider)
  end

  test "explicit empty stopped text reaches the model while Code Mode retains the native value" do
    ctx = start(:stopped, text: "")
    provider = prompt(ctx)

    code =
      "const result = await tools.update_plan({plan:[{step:'kept',status:'completed'}]}); return {original:result.revision};"

    {request, provider} = call(provider, "exec", code)

    assert List.last(request.messages).result == %{
             is_error: false,
             stopped: true,
             content: [%{type: :text, text: ""}]
           }

    assert_receive {:actual_effect, operation, %{revision: 2}}
    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    assert {:ok, %{run: stored}} = EphemeralStore.load(ctx.table, ctx.run)
    assert stored.tool_results[operation.invocation_id].revision == 2
    refute stored.tool_results[operation.invocation_id].is_error
    presentation = stored.tool_presentations[operation.invocation_id]
    assert presentation.decision == %{type: :stopped, text: ""}
    enclosing = presentation.identity.enclosing_invocation_id
    assert stored.tool_results[enclosing].value["original"] == 2
    assert stored.tool_presentations[enclosing].decision == %{type: :stopped, text: ""}
    finish(ctx, provider)
  end

  test "direct repeated calls and reused call IDs retain separate actual results and projections" do
    ctx = start(:block)
    provider = prompt(ctx)
    args = %{"plan" => [%{"step" => "same", "status" => "completed"}]}
    {request, provider} = call(provider, "update_plan", args, "reused")
    assert List.last(request.messages).result.error.message == "host presentation"
    {request, provider} = call(provider, "update_plan", args, "reused")
    assert List.last(request.messages).result.is_error
    assert {:ok, %{revision: 3}} = Plan.read(ctx.plan)
    assert {:ok, stored} = EphemeralStore.load(ctx.table, ctx.run)
    assert map_size(stored.run.tool_presentations) == 2

    assert Enum.map(stored.run.tool_results, fn {_id, value} -> value.revision end) |> Enum.sort() ==
             [2, 3]

    finish(ctx, provider)
  end

  test "selected durable settlement reconstructs unprojected history without replaying a native hook" do
    ctx = start(:stopped, lost_ack: true)
    provider = prompt(ctx)
    send_call(provider, "update_plan", %{"plan" => []}, "lost")
    assert_receive :presentation_committed_without_ack, 5000
    assert_receive {:actual_effect, _, _}
    eventually(fn -> Conversation.status(ctx.pid).phase == :storage_failed end)
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.table, ctx.run)
    assert map_size(run.tool_presentations) == 1
    refute Enum.any?(run.context.conversation.messages, &(&1[:role] == :tool))

    {:ok, restored} =
      Conversation.start_link(
        Keyword.merge(ctx.opts, run: run, store: EphemeralStore, context: ctx.table)
        |> Keyword.delete(:session_binding)
      )

    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert List.last(Conversation.status(restored).messages).result.stopped
    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    refute_receive {:actual_effect, _, _}
  end

  test "selected settlement restores explicit empty stopped text without replaying the native effect" do
    ctx = start(:stopped, text: "", lost_ack: true)
    provider = prompt(ctx)
    send_call(provider, "update_plan", %{"plan" => []}, "empty-stopped")
    assert_receive :presentation_committed_without_ack, 5000
    assert_receive {:actual_effect, operation, %{revision: 2}}
    eventually(fn -> Conversation.status(ctx.pid).phase == :storage_failed end)
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.table, ctx.run)
    assert run.tool_presentations[operation.invocation_id].decision == %{type: :stopped, text: ""}
    refute run.tool_results[operation.invocation_id].is_error
    refute Enum.any?(run.context.conversation.messages, &(&1[:role] == :tool))

    restored =
      start_supervised!(
        {Conversation,
         Keyword.merge(ctx.opts, run: run, store: EphemeralStore, context: ctx.table)
         |> Keyword.delete(:session_binding)},
        id: :empty_stopped_restored
      )

    assert List.last(Conversation.status(restored).messages).result == %{
             is_error: false,
             stopped: true,
             content: [%{type: :text, text: ""}]
           }

    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    refute_receive {:actual_effect, _, _}
  end

  test "a presented call after a true generator yield uses the wait invocation boundary" do
    ctx = start(:block)
    provider = prompt(ctx)

    code =
      "yield 'pause'; try { await tools.update_plan({plan:[]}); return 'unexpected'; } catch (_) { return 'caught after wait'; }"

    {request, provider} = call(provider, "exec", code)
    assert %{status: :yielded, cell_id: cell} = List.last(request.messages).result
    refute_receive {:actual_effect, _, _}
    {request, provider} = call(provider, "wait", %{"cell_id" => cell, "yield_time_ms" => 1000})
    assert List.last(request.messages).result.value == "caught after wait"
    assert_receive {:actual_effect, operation, _}
    assert {:ok, stored} = EphemeralStore.load(ctx.table, ctx.run)
    presentation = stored.run.tool_presentations[operation.invocation_id]
    wait_id = presentation.identity.enclosing_invocation_id
    assert stored.run.tool_results[wait_id].status == :completed
    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    finish(ctx, provider)
  end

  test "presentation envelope cannot be reused for another invocation or forged as a normal result" do
    operation = %{
      run_id: "r",
      incarnation: 1,
      step_id: "s",
      attempt_id: "a",
      invocation_id: "i",
      enclosing_invocation_id: "i",
      tool_name: "native",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      arguments: %{}
    }

    assert {:presented, envelope} =
             ToolEffects.present(operation, %{revision: 2}, %{type: :block, text: "blocked"})

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_presentation(envelope, %{operation | invocation_id: "other"})

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.present(operation, %{}, %{type: :block, text: "", private: self()})

    assert {:ok, %{result: %ToolEffects.PresentedResult{result: %{value: "actual"}}}} =
             ToolEffects.execute(PresentedBackend, operation, %{})

    assert {:ok, result} = ToolEffects.validate_presentation(envelope, operation)
    assert ToolEffects.settlement({:ok, result}, %{read_only: false}) == :settled
  end

  test "nested stopped bound collaboration retains its binding without copying it into ordinary wait" do
    run = "bound-presentation-#{System.unique_integer([:positive])}"
    names = ["exec", "wait", "host::bound_list"]
    authority = %{caller: "presentation-host", run_id: run, grants: names, tool_revision: 1}

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: run,
         parent_name: "/root",
         parent_authority: authority,
         child_options: fn _, _, _ ->
           {:error, Error.new(:forbidden, "this fixture does not spawn children")}
         end}
      )

    {:ok, bound} =
      MultiAgent.bind_contract(manager, :list, %{
        namespace: "host",
        name: "bound_list",
        tool_revision: 1,
        backend: PresentedBound,
        backend_context: %{test: self()},
        schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        safety: %{read_only: true, retry_safe: false, parallel_safe: false}
      })

    authority =
      Map.put(authority, :tool_bindings, %{
        "host::bound_list" => bound.collaboration_binding.fingerprint
      })

    session = start_supervised!({Session, owner_pid: self()})
    {:ok, binding} = Session.bind(session, authority)

    context = %{
      resource_registry: binding.resource_registry,
      session_binding: binding,
      caller: %{run_id: run},
      deno_path: System.find_executable("deno")
    }

    {:ok, profile} = Catalog.admit(CodeMode.contracts(context) ++ [bound], authority)

    registry = %{
      profile.registry
      | tools:
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            {name, put_in(descriptor.backend_context[:session_binding], binding)}
          end)
    }

    {:ok, table} = EphemeralStore.new(1)

    opts = [
      run_id: run,
      store: EphemeralStore,
      context: table,
      provider: Provider,
      provider_context: %{test: self()},
      registry: registry,
      tools: profile.tools,
      authority: profile.authority,
      session_binding: binding,
      schema_admission: :strict,
      subscriber: self(),
      effect_timeout: 15_000,
      run_timeout: 30_000
    ]

    pid = start_supervised!({Conversation, opts})
    ctx = %{run: run, pid: pid, table: table, session: session}
    provider = prompt(ctx)

    code =
      "yield 'before bound call'; const result = await codex.tool('host::bound_list', {}); return {count:result.agents.length};"

    {request, provider} = call(provider, "exec", code)
    assert %{status: :yielded, cell_id: cell} = List.last(request.messages).result
    refute_receive {:bound_actual_effect, _, _}
    {request, provider} = call(provider, "wait", %{"cell_id" => cell, "yield_time_ms" => 1_000})
    assert List.last(request.messages).result.stopped
    assert_receive {:bound_actual_effect, nested, actual}
    assert actual.agents == []
    assert nested.collaboration_binding == bound.collaboration_binding

    assert {:ok, %{run: stored}} = EphemeralStore.load(table, run)
    assert stored.tool_results[nested.invocation_id].agents == []
    refute stored.tool_results[nested.invocation_id].is_error

    assert stored.tool_presentations[nested.invocation_id].identity.collaboration_binding ==
             bound.collaboration_binding

    wait_id = stored.tool_presentations[nested.invocation_id].identity.enclosing_invocation_id
    assert stored.tool_results[wait_id].status == :completed
    assert stored.tool_results[wait_id].value["count"] == 0
    wait_operation = stored.execution_intents["tool:" <> wait_id].operation
    refute Map.has_key?(wait_operation, :collaboration_binding)
    refute Map.has_key?(stored.tool_presentations[wait_id].identity, :collaboration_binding)

    assert stored.tool_presentations[wait_id].identity ==
             ToolEffects.presentation_identity(wait_operation)

    assert stored.active_tools == %{}
    finish(ctx, provider)
  end

  defp start(type, extra \\ []) do
    run = "presentation-#{System.unique_integer([:positive])}"
    names = ["exec", "wait", "update_plan"]
    authority = %{caller: "presentation-host", run_id: run, grants: names, tool_revision: 1}
    session = start_supervised!({Session, owner_pid: self()})
    {:ok, binding} = Session.bind(session, authority)
    {:ok, plan} = Plan.start_link(run)
    on_exit(fn -> if Process.alive?(plan), do: GenServer.stop(plan) end)

    {:ok, profile} =
      Codex.profile(
        :configured,
        %{session_binding: binding, plan: plan, deno_path: System.find_executable("deno")},
        authority,
        families: [:local, :code_mode],
        tools: names
      )

    descriptor = profile.registry.tools["update_plan"]

    descriptor = %{
      descriptor
      | backend: DecoratedNative,
        backend_context:
          Map.merge(
            descriptor.backend_context,
            %{
              test: self(),
              presentation: %{type: type, text: Keyword.get(extra, :text, "host presentation")}
            }
          )
    }

    profile = put_in(profile.registry.tools["update_plan"], descriptor)
    {:ok, table} = EphemeralStore.new(1)

    {store, context} =
      if extra[:lost_ack],
        do: {LostAckStore, %{table: table, test: self()}},
        else: {EphemeralStore, table}

    opts = [
      run_id: run,
      store: store,
      context: context,
      provider: Provider,
      provider_context: %{test: self()},
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      session_binding: binding,
      schema_admission: :strict,
      subscriber: self(),
      effect_timeout: 15000,
      run_timeout: 30000
    ]

    pid = start_supervised!({Conversation, opts})
    %{run: run, pid: pid, plan: plan, session: session, table: table, opts: opts}
  end

  defp prompt(ctx) do
    assert {:ok, _} = Conversation.prompt(ctx.pid, "exercise result presentation")
    assert_receive {:presentation_provider, _, provider}, 5000
    provider
  end

  defp call(provider, name, args, id \\ "call") do
    send_call(provider, name, args, id)
    assert_receive {:presentation_provider, request, next}, 15000
    {request, next}
  end

  defp send_call(provider, name, args, id) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: args}},
         %{type: :response_completed, message: %{role: :assistant, content: "working"}}
       ]}
    )
  end

  defp finish(ctx, provider) do
    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    run = ctx.run
    assert_receive {:agent_runtime, ^run, %{type: :run_completed}}, 5000
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  defp eventually(fun, remaining \\ 100)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end

  defp eventually(_fun, 0), do: flunk("state did not converge")
end
