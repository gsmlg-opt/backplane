defmodule Backplane.AgentRuntime.CodexSourceConformanceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Contract, ResourceRegistry}

  @fixture Path.expand("../../fixtures/code_mode_source/contract.json", __DIR__)
  @source JSON.decode!(File.read!(@fixture))

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:source_provider, request, self()})

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

  defmodule ObservingBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:source_nested, operation})
      {:ok, %{value: operation.arguments["value"]}}
    end
  end

  defmodule CatalogBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:source_swap, self()})

      receive do
        {:publish, update} ->
          receipt = operation.backend_context.stage_catalog.(update)
          send(operation.backend_context.test, {:source_publication, receipt})
          {:ok, %{published: true}}
      end
    end
  end

  setup do
    registry = start_supervised!(ResourceRegistry)
    deno = System.find_executable("deno") || System.get_env("DENO_PATH")
    assert is_binary(deno), "source contract fixtures require the real packaged Deno worker"

    %{
      registry: registry,
      opts: [
        deno_path: deno,
        dispatcher: fn _, _ -> {:ok, %{}} end,
        timeout: 3_000,
        yield_time_ms: 1_000
      ]
    }
  end

  test "independent fixtures freeze source provenance rather than claiming native differential execution" do
    assert @source["codex_commit"] == "46fdd5ef39735f4159cdcf0ec5e85c10521494e5"
    assert @source["method"] =~ "neither captured nor executed"
    assert Enum.all?(@source["sources"], &(byte_size(&1["sha256"]) == 64))
  end

  test "explicit yields wait for admitted callbacks before returning a cell", %{
    registry: registry,
    opts: opts
  } do
    parent = self()

    for {owner, code} <- [
          {"control",
           "const pending = codex.tool('write', {}); await new Promise(r => setTimeout(r, 30)); yield_control(); await pending; await new Promise(r => setTimeout(r, 80));"},
          {"generator",
           "const pending = codex.tool('write', {}); await new Promise(r => setTimeout(r, 30)); yield 'paused'; await pending;"}
        ] do
      dispatcher = fn _, _ ->
        send(parent, {:yield_callback, self()})
        receive do: (:settle -> {:ok, :settled})
      end

      task =
        Task.async(fn ->
          CodeMode.execute(
            registry,
            owner,
            code,
            Keyword.merge(opts, dispatcher: dispatcher, owner_pid: parent)
          )
        end)

      assert_receive {:yield_callback, callback}, 2_000
      ref = task.ref
      refute_receive {^ref, _}, 100
      send(callback, :settle)
      assert {:ok, %{status: :yielded, handle: handle}} = Task.await(task)
      assert {:ok, worker} = ResourceRegistry.fetch(registry, handle, owner)
      assert CodeMode.Worker.ready_for_detach(worker)
      assert {:ok, %{status: :completed}} = CodeMode.resume(registry, handle, nil, owner: owner)
    end
  end

  test "wait refreshes shared stored state without losing the cell's earlier writes", %{
    registry: registry,
    opts: opts
  } do
    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(
               registry,
               "shared",
               "store('own', 1); yield 'paused'; text(load('other')); text(load('own'));",
               opts
             )

    assert {:ok, %{status: :completed}} =
             CodeMode.execute(registry, "shared", "store('other', 2);", opts)

    assert {:ok, %{status: :completed, output: [%{"text" => "2"}, %{"text" => "1"}]}} =
             CodeMode.resume(registry, handle, nil, owner: "shared")
  end

  for fixture <- @source["completion_cases"] do
    @completion fixture
    test "source helper fixture: #{fixture["id"]}", %{registry: registry, opts: opts} do
      assert {:ok, %{status: :completed, output: output}} =
               CodeMode.execute(registry, unquote(fixture["id"]), @completion["code"], opts)

      assert output == @completion["output"]
    end
  end

  test "source pragma parser and defaults use source-defined options", %{
    registry: registry,
    opts: opts
  } do
    for fixture <- @source["pragma_cases"] do
      owner = fixture["id"]

      assert {:ok, %{status: :yielded, cell_id: id}} =
               CodeMode.call(operation(registry, owner, fixture["code"], opts))

      handle = handle(id, owner)
      assert {:ok, worker} = ResourceRegistry.fetch(registry, handle, owner)
      state = :sys.get_state(worker)
      assert state.yield_time_ms == fixture["yield_time_ms"]
      assert state.max_tokens == fixture["max_output_tokens"]
      assert {:ok, _} = CodeMode.cancel(registry, handle, owner)
    end

    for code <- @source["invalid_source_cases"] do
      assert {:error, %Error{class: :validation}} =
               CodeMode.call(operation(registry, "bad-pragma", code, opts))
    end

    assert {:ok, %{status: :completed, output: []}} =
             CodeMode.call(
               operation(
                 registry,
                 "zero",
                 "// @exec: {\"max_output_tokens\":0}\ntext('omitted');",
                 opts
               )
             )
  end

  test "raw dispatch and metadata discovery use namespaced tools with custom input", %{
    registry: registry,
    opts: opts
  } do
    test = self()

    dispatch = fn request, _context ->
      send(test, {:raw_source_call, request})
      {:ok, "accepted"}
    end

    opts =
      Keyword.merge(opts,
        dispatcher: dispatch,
        tools: [
          %{name: "editor::apply_patch", description: "Apply raw patch", input_kind: :custom}
        ]
      )

    code =
      "const tool = ALL_TOOLS.find(t => t.description.includes('raw patch')); text(await tools.editor__apply_patch('*** Begin Patch\\n*** End Patch\\n'));"

    assert {:ok, %{status: :completed, output: [%{"type" => "text", "text" => "accepted"}]}} =
             CodeMode.execute(registry, "custom", code, opts)

    assert_receive {:raw_source_call,
                    %{
                      tool_name: "editor::apply_patch",
                      input_kind: :custom,
                      raw_input: "*** Begin Patch\n*** End Patch\n"
                    }}
  end

  test "running cells retain incremental output and ignore detached control flushes", %{
    registry: registry,
    opts: opts
  } do
    code =
      "text('first'); await new Promise(r => setTimeout(r, 150)); yield_control(); text('last');"

    assert {:ok, %{status: :yielded, handle: cell, output: first}} =
             CodeMode.execute(registry, "running", code, Keyword.put(opts, :yield_time_ms, 20))

    Process.sleep(250)

    assert {:ok, %{status: :completed, output: last}} =
             CodeMode.resume(registry, cell, nil, owner: "running", yield_time_ms: 200)

    assert Enum.map(first ++ last, & &1["text"]) == ["first", "last"]

    assert {:error, %Error{class: :not_found}} =
             CodeMode.resume(registry, cell, nil, owner: "running")

    assert {:error, %Error{class: :not_found}} =
             CodeMode.resume(registry, handle("never-yielded", "running"), nil, owner: "running")
  end

  test "stored values are shared only within the exact owner incarnation", %{
    registry: registry,
    opts: opts
  } do
    assert {:ok, %{status: :completed}} =
             CodeMode.execute(registry, "session", "store('value', {n:3});", opts)

    assert {:ok, %{output: [%{"text" => "3"}]}} =
             CodeMode.execute(registry, "session", "text(load('value').n);", opts)

    assert {:ok, %{output: [%{"text" => "undefined"}]}} =
             CodeMode.execute(
               registry,
               "session",
               "text(load('value'));",
               Keyword.put(opts, :incarnation, 2)
             )

    assert {:ok, %{output: [%{"text" => "undefined"}]}} =
             CodeMode.execute(registry, "other", "text(load('value'));", opts)

    assert {:ok, _} = ResourceRegistry.close_owner(registry, "session")

    assert {:error, %Error{}} =
             CodeMode.execute(registry, "session", "text(load('value'));", opts)
  end

  test "late state writes cannot revive released or closed-owner cells", %{registry: registry} do
    assert {:ok, cell} =
             ResourceRegistry.register(registry, "state-owner", :continuation, :fake,
               incarnation: 1
             )

    assert :ok = ResourceRegistry.store_code_state(registry, cell, "state-owner", "before", 1)

    assert {:error, %Error{}} =
             ResourceRegistry.store_code_state(
               registry,
               %{cell | incarnation: 2},
               "state-owner",
               "stale",
               2
             )

    assert {:ok, _} = ResourceRegistry.release(registry, cell, "state-owner")

    assert {:error, %Error{}} =
             ResourceRegistry.store_code_state(registry, cell, "state-owner", "late", 3)

    assert {:ok, replacement} =
             ResourceRegistry.register(registry, "state-owner", :continuation, :fake,
               incarnation: 2
             )

    assert :ok = ResourceRegistry.store_code_state(registry, replacement, "state-owner", "new", 4)
    assert ResourceRegistry.code_state(registry, "state-owner", 1) == %{"before" => 1}
    assert ResourceRegistry.code_state(registry, "state-owner", 2) == %{"new" => 4}
    assert {:ok, _} = ResourceRegistry.close_owner(registry, "state-owner")

    assert {:error, %Error{}} =
             ResourceRegistry.store_code_state(
               registry,
               replacement,
               "state-owner",
               "after-close",
               5
             )

    assert {:error, %Error{}} = ResourceRegistry.code_state(registry, "state-owner", 2)
  end

  test "real stale deadline and slice generations are ignored after resume", %{
    registry: registry,
    opts: opts
  } do
    test = self()

    dispatch = fn _request, context ->
      send(test, {:timer_callback, self(), context})
      receive do: (:release -> {:ok, "released"})
    end

    code =
      "await codex.tool('echo', {}); yield 'checkpoint'; await new Promise(r => setTimeout(r, 160)); text('done');"

    task =
      Task.async(fn ->
        CodeMode.execute(
          registry,
          "timers",
          code,
          Keyword.merge(opts, dispatcher: dispatch, owner_pid: test)
        )
      end)

    assert_receive {:timer_callback, callback, _context}, 5_000
    {cell, worker} = live_cell(registry, "timers")
    armed = :sys.get_state(worker)
    assert is_reference(armed.timer_generation)
    assert is_reference(armed.slice_generation)
    send(callback, :release)
    assert {:ok, %{status: :yielded, handle: ^cell}} = Task.await(task, 5_000)

    assert {:ok, %{status: :yielded}} =
             CodeMode.resume(registry, cell, nil, owner: "timers", yield_time_ms: 20)

    resumed = :sys.get_state(worker)
    assert resumed.timer_generation != armed.timer_generation
    send(worker, {:deadline, armed.timer_generation})
    send(worker, {:slice, armed.slice_generation})

    assert {:ok, %{status: :completed, output: [%{"text" => "done"}]}} =
             CodeMode.resume(registry, cell, nil, owner: "timers", yield_time_ms: 1_000)
  end

  test "unawaited or crashed callbacks preserve uncertain side-effect evidence", %{
    registry: registry,
    opts: opts
  } do
    test = self()

    block = fn _, _ ->
      send(test, {:inflight_callback, self()})
      receive do: (:never -> {:ok, "late"})
    end

    task =
      Task.async(fn ->
        CodeMode.execute(
          registry,
          "unawaited",
          "codex.tool('write', {}); await new Promise(r => setTimeout(r, 80));",
          Keyword.put(opts, :dispatcher, block)
        )
      end)

    assert_receive {:inflight_callback, callback}, 5_000
    monitor = Process.monitor(callback)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 5_000
    crash = fn _, _ -> exit(:effect_outcome_unknown) end

    assert {:error, %Error{class: :unknown_outcome}} =
             CodeMode.execute(
               registry,
               "crash",
               "await codex.tool('write', {});",
               Keyword.put(opts, :dispatcher, crash)
             )

    assert {:error, %Error{class: :execution_failure}} =
             CodeMode.execute(registry, "exception", "throw new Error('source exception');", opts)
  end

  test "detached notifications obey the hard output bound and close terminal resources", %{
    registry: registry,
    opts: opts
  } do
    code =
      "await new Promise(r => setTimeout(r, 120)); for (let i=0; i<20; i++) notify('x'.repeat(128));"

    assert {:ok, %{status: :yielded, handle: cell}} =
             CodeMode.execute(
               registry,
               "notifications",
               code,
               Keyword.merge(opts, yield_time_ms: 20, output_limit: 256)
             )

    Process.sleep(220)

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.resume(registry, cell, nil, owner: "notifications", yield_time_ms: 1_000)

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch(registry, cell, "notifications")
  end

  test "the packaged adapter grants no ambient filesystem or network access", %{
    registry: registry,
    opts: opts
  } do
    for {owner, code} <- [
          {"no-network", "await fetch('https://example.invalid');"},
          {"no-filesystem",
           "const fs = await import('node:fs/promises'); await fs.readFile('/etc/passwd');"}
        ] do
      assert {:error, %Error{class: :execution_failure}} =
               CodeMode.execute(registry, owner, code, opts)
    end

    assert {:ok, %{output: [%{"text" => "undefined"}]}} =
             CodeMode.execute(registry, "no-deno-global", "text(typeof Deno);", opts)
  end

  test "notify emits immediately through an admitted Conversation effect", %{registry: registry} do
    run = "source-notify"
    {conversation, provider, _profile} = start_conversation(registry, run, 1)
    code = "notify({ready:true}); await new Promise(r => setTimeout(r, 200)); text('completed');"
    send(provider, {:events, [call("notify-exec", "exec", code), done()]})

    assert_receive {:agent_runtime, ^run,
                    %{type: :custom_tool_call_output, output: "{\"ready\":true}"}},
                   5_000

    refute_receive {:agent_runtime, ^run, %{type: :tool_completed}}, 50
    assert_receive {:agent_runtime, ^run, %{type: :tool_completed}}, 5_000
    assert_receive {:source_provider, %{messages: messages}, _next}, 5_000
    assert %{is_error: false, output: [%{"text" => "completed"}]} = List.last(messages).result
    assert :ok = Conversation.cancel(conversation)
  end

  test "timesliced nested dispatch uses the newly committed Conversation catalog and authority",
       %{registry: registry} do
    run = "source-authority"
    {conversation, provider, initial} = start_conversation(registry, run, 1)

    code =
      "// @exec: {\"yield_time_ms\":20}\nawait new Promise(r => setTimeout(r, 1000)); text(await tools.mcp__echo({value:7}));"

    send(provider, {:events, [call("authority-exec", "exec", code), done()]})
    assert_receive {:source_provider, %{messages: messages}, second}, 5_000
    assert %{is_error: false, status: :yielded, cell_id: id} = List.last(messages).result
    current = profile(registry, run, 2)

    update = %{
      publication_id: "current",
      run_id: run,
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: current.registry,
        authority: current.authority,
        tools:
          Enum.map(current.contracts, fn {_name, contract} ->
            Contract.provider_definition(contract)
          end)
      }
    }

    send(second, {:events, [call("catalog-exec", "exec", "await tools.mcp__swap({});"), done()]})
    assert_receive {:source_swap, swap}, 5_000
    send(swap, {:publish, update})
    assert_receive {:source_publication, {:ok, %{status: :staged}}}, 5_000
    assert_receive {:source_provider, %{catalog_revision: 2}, third}, 5_000
    Process.sleep(1_100)
    refute_receive {:source_nested, _}, 20

    send(
      third,
      {:events,
       [call("authority-wait", "wait", %{"cell_id" => id, "yield_time_ms" => 1_000}), done()]}
    )

    assert_receive {:source_nested, nested}, 5_000
    assert nested.catalog_revision == 2
    assert nested.effective_authority.tool_revisions["mcp::echo"] == 2
    assert nested.backend_context.generation == 2
    assert Map.take(nested.effective_authority, Map.keys(current.authority)) == current.authority
    refute nested.effective_authority == initial.authority
    assert_receive {:source_provider, %{messages: completed}, _last}, 5_000
    assert %{is_error: false, status: :completed} = List.last(completed).result
    assert :ok = Conversation.cancel(conversation)
  end

  defp operation(registry, owner, code, opts) do
    %{
      tool_name: "exec",
      arguments: code,
      run_id: owner,
      incarnation: 1,
      effective_authority: %{run_id: owner, grants: []},
      catalog_revision: 1,
      backend_context: %{
        context: %{
          resource_registry: registry,
          deno_path: opts[:deno_path],
          timeout: opts[:timeout]
        },
        nested_dispatch: fn _ -> {:ok, %{}} end
      }
    }
  end

  defp handle(id, owner),
    do: %{resource_id: id, owner_id: owner, incarnation: 1, kind: :continuation}

  defp live_cell(registry, owner) do
    state = :sys.get_state(registry)
    {_, entry} = Enum.find(state.resources, fn {_key, entry} -> entry.owner_id == owner end)
    {entry.handle, entry.value}
  end

  defp profile(registry, run, revision) do
    schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer"}},
      "required" => ["value"],
      "additionalProperties" => false
    }

    target = %{
      namespace: "mcp",
      name: "echo",
      description: "Source echo",
      schema: schema,
      tool_revision: revision,
      backend: ObservingBackend,
      backend_context: %{test: self(), generation: revision},
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    swap = %{
      namespace: "mcp",
      name: "swap",
      description: "Publish a host catalog",
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      backend: CatalogBackend,
      backend_context: %{test: self()},
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    context = %{
      resource_registry: registry,
      deno_path: System.find_executable("deno") || System.get_env("DENO_PATH"),
      code_mode_contracts: [target, swap],
      timeout: 5_000
    }

    authority = %{
      caller: "source-host",
      run_id: run,
      grants: ["exec", "wait", "mcp::echo", "mcp::swap"],
      tool_revisions: %{"exec" => 1, "wait" => 1, "mcp::echo" => revision, "mcp::swap" => 1}
    }

    assert {:ok, profile} = Codex.profile(:code_mode_only, context, authority)
    profile
  end

  defp start_conversation(registry, run, revision) do
    profile = profile(registry, run, revision)
    {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         work: 24,
         run_timeout: 15_000},
        id: run
      )

    assert {:ok, _} = Conversation.prompt(conversation, "run source case")
    assert_receive {:source_provider, _, provider}, 5_000
    {conversation, provider, profile}
  end

  defp call(id, name, arguments),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}

  defp done,
    do: %{type: :response_completed, message: %{role: :assistant, content: "source fixture"}}
end
