defmodule Backplane.AgentRuntime.CodexCatalogExposureIntegrationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{CodeMode, ExtensionRuntime, ResourceRegistry, Session}

  @history ~w(history::list_windows history::list_items history::read_item history::search_contents)
  @notes ~w(notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file)
  @modes [
    %{"type" => "any"},
    %{"type" => "all_on_same_line"},
    %{"type" => "all_within_lines", "line_count" => 3}
  ]

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:catalog_provider, request, self()})

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

  defmodule Adapter do
    def execute(operation, scope, %{test: test}) do
      send(test, {:extension_operation, operation.tool_name, operation.arguments, scope})
      {:ok, %{sentinel: "direct host result"}}
    end
  end

  test "History and Notes stay directly callable while real Deno and resumed wait exclude them" do
    names = ["exec", "wait" | @history ++ @notes]
    ctx = context(names)

    assert {:ok, profile} =
             Codex.profile(:configured, ctx.context, ctx.authority,
               families: [:extensions, :code_mode],
               tools: names
             )

    assert MapSet.new(Enum.map(profile.tools, & &1.name)) == MapSet.new(names)
    assert MapSet.new(profile.authority.grants) == MapSet.new(names)

    for name <- @history ++ @notes do
      assert profile.registry.tools[name].codex_exposure == :direct_model_only
    end

    for variant <- [:mixed, :code_mode_only] do
      targets =
        ExtensionRuntime.contracts(ctx.context)
        |> Enum.filter(&(&1.namespace in ["history", "notes"]))

      assert {:ok, composed} =
               Codex.profile(
                 variant,
                 Map.put(ctx.context, :code_mode_contracts, targets),
                 ctx.authority,
                 tools: names
               )

      assert MapSet.new(Enum.map(composed.tools, & &1.name)) == MapSet.new(names)
      assert composed.registry.tools["history::read_item"].codex_exposure == :direct_model_only
    end

    conversation = conversation(ctx, profile)
    provider = prompt(conversation)
    request = call(provider, "history::read_item", %{"window_id" => "w", "item_id" => "i"})
    assert List.last(request.messages).result.sentinel == "direct host result"
    assert_receive {:extension_operation, "history::read_item", _, _}

    request =
      call(request.provider, "notes::write_file", %{"path" => "fixture.md", "text" => "safe"})

    assert List.last(request.messages).result.sentinel == "direct host result"
    assert_receive {:extension_operation, "notes::write_file", _, _}

    code = """
    const names = ['history::read_item', 'notes::write_file'];
    const args = [{window_id:'w',item_id:'i'}, {path:'fixture.md',text:'safe'}];
    const errors = [];
    for (let i=0; i<names.length; i++) {
      try { await codex.tool(names[i], args[i]); errors.push(false); }
      catch (_) { errors.push(true); }
    }
    store('before', {listed: ALL_TOOLS.map(x => x.tool_name),
      historyAlias: typeof tools.history__read_item, noteAlias: typeof tools.notes__write_file, errors});
    await yield_control();
    const resumed = [];
    for (let i=0; i<names.length; i++) {
      try { await codex.tool(names[i], args[i]); resumed.push(false); }
      catch (_) { resumed.push(true); }
    }
    return {before: load('before'), listed: ALL_TOOLS.map(x => x.tool_name), resumed};
    """

    request = call(request.provider, "exec", "// @exec: {\"yield_time_ms\":1000}\n" <> code)
    assert %{status: :yielded, cell_id: cell_id} = List.last(request.messages).result
    request = call(request.provider, "wait", %{"cell_id" => cell_id, "yield_time_ms" => 1000})
    assert %{status: :completed, value: value} = List.last(request.messages).result
    assert value["before"]["historyAlias"] == "undefined"
    assert value["before"]["noteAlias"] == "undefined"
    assert value["before"]["errors"] == [true, true]
    assert value["resumed"] == [true, true]
    assert Enum.all?(@history ++ @notes, &(&1 not in value["before"]["listed"]))
    assert Enum.all?(@history ++ @notes, &(&1 not in value["listed"]))
    refute_received {:extension_operation, _, _, _}
    finish(ctx, request.provider)
  end

  test "all tagged memory modes reach the host unchanged through direct and actual Deno dispatch" do
    names = ["exec", "wait", "memories::search"]
    ctx = context(names)

    assert {:ok, profile} =
             Codex.profile(:configured, ctx.context, ctx.authority,
               families: [:extensions, :code_mode],
               tools: names
             )

    conversation = conversation(ctx, profile)
    provider = prompt(conversation)

    provider =
      Enum.reduce(@modes, provider, fn mode, provider ->
        arguments = %{"queries" => ["alpha", "beta"], "match_mode" => mode}
        request = call(provider, "memories::search", arguments)
        assert_receive {:extension_operation, "memories::search", ^arguments, scope}
        assert scope == ctx.scope
        request.provider
      end)

    code = """
    const modes = #{JSON.encode!(@modes)};
    const results = [];
    for (const mode of modes) {
      results.push(await tools.memories__search({queries:['alpha','beta'],match_mode:mode}));
    }
    return results;
    """

    request = call(provider, "exec", "// @exec: {\"yield_time_ms\":1000}\n" <> code)
    assert %{status: :completed, value: results} = List.last(request.messages).result
    assert length(results) == 3

    for mode <- @modes do
      arguments = %{"queries" => ["alpha", "beta"], "match_mode" => mode}
      assert_receive {:extension_operation, "memories::search", ^arguments, scope}
      assert scope == ctx.scope
    end

    finish(ctx, request.provider)
  end

  test "wait refreshes metadata after a catalog changes exposure and retains ordinary direct tools" do
    registry = start_supervised!(ResourceRegistry)

    descriptors =
      Map.new(["history::read_item", "ordinary"], fn name ->
        {name, %{tool_name: name, codex_exposure: :direct}}
      end)

    operation = %{
      tool_name: "exec",
      run_id: "refresh",
      incarnation: 1,
      catalog_revision: 1,
      effective_authority: %{grants: Map.keys(descriptors)},
      arguments:
        "// @exec: {\"yield_time_ms\":1000}\nstore('initial', ALL_TOOLS.map(x => x.tool_name)); yield 'refresh'; return {initial:load('initial'), current:ALL_TOOLS.map(x => x.tool_name), historyAlias:typeof tools.history__read_item, ordinaryAlias:typeof tools.ordinary};",
      backend_context: %{
        context: %{resource_registry: registry, deno_path: System.find_executable("deno")},
        resource_owner_pid: self(),
        nested_dispatch: fn _ -> flunk("metadata check dispatched a tool") end,
        catalog_snapshot: %{revision: 1, registry: %ToolRegistry{tools: descriptors}}
      }
    }

    assert {:ok, %{status: :yielded, cell_id: cell_id}} = CodeMode.call(operation)
    descriptors = put_in(descriptors, ["history::read_item", :codex_exposure], :direct_model_only)

    wait = %{
      operation
      | tool_name: "wait",
        arguments: %{"cell_id" => cell_id, "yield_time_ms" => 1000},
        catalog_revision: 2,
        backend_context: %{
          operation.backend_context
          | catalog_snapshot: %{revision: 2, registry: %ToolRegistry{tools: descriptors}}
        }
    }

    assert {:ok, %{status: :completed, value: result}} = CodeMode.call(wait)
    assert "history::read_item" in result["initial"]
    assert result["current"] == ["ordinary"]
    assert result["historyAlias"] == "undefined"
    assert result["ordinaryAlias"] == "function"
  end

  defp context(names) do
    run = "catalog-boundary-#{System.unique_integer([:positive])}"

    authority = %{
      caller: "catalog-host",
      run_id: run,
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority)

    scope = %{
      host_id: binding.owner_id,
      caller_id: authority.caller,
      run_id: run,
      project_id: "catalog-boundary"
    }

    runtime =
      start_supervised!(
        {ExtensionRuntime,
         owner_pid: self(), scope: scope, adapter: Adapter, adapter_context: %{test: self()}}
      )

    context = %{
      session_binding: binding,
      resource_registry: binding.resource_registry,
      extension_runtime: runtime,
      deno_path: System.find_executable("deno")
    }

    %{context: context, authority: authority, session: session, binding: binding, scope: scope}
  end

  defp conversation(ctx, profile) do
    assert {:ok, store} = EphemeralStore.new(1)

    start_supervised!(
      {Conversation,
       run_id: ctx.authority.run_id,
       store: EphemeralStore,
       context: store,
       provider: Provider,
       provider_context: %{test: self()},
       subscriber: self(),
       registry: profile.registry,
       tools: profile.tools,
       authority: profile.authority,
       session_binding: ctx.binding,
       schema_admission: :strict,
       work: 40,
       effect_timeout: 15_000,
       run_timeout: 30_000}
    )
  end

  defp prompt(conversation) do
    assert {:ok, _} = Conversation.prompt(conversation, "exercise catalog boundary")
    assert_receive {:catalog_provider, _, provider}, 5_000
    provider
  end

  defp call(provider, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "call-#{System.unique_integer([:positive])}",
             name: name,
             arguments: arguments
           }
         },
         %{type: :response_completed, message: %{role: :assistant, content: "working"}}
       ]}
    )

    assert_receive {:catalog_provider, request, next_provider}, 15_000
    Map.put(request, :provider, next_provider)
  end

  defp finish(ctx, provider) do
    send(
      provider,
      {:events,
       [
         %{type: :response_completed, message: %{role: :assistant, content: "done"}}
       ]}
    )

    run = ctx.authority.run_id
    assert_receive {:agent_runtime, ^run, %{type: :run_completed}}, 5_000
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end
end
