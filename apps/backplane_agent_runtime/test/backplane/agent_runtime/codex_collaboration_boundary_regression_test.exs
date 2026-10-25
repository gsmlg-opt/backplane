defmodule Backplane.AgentRuntime.CodexCollaborationBoundaryRegressionTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Conversation, EphemeralStore, Error}

  alias Backplane.AgentRuntime.Codex.{
    Catalog,
    Contract,
    DynamicRuntime,
    MultiAgent,
    Session,
    Tools
  }

  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @collaboration ~w(spawn_agent list_agents followup_task send_message interrupt_agent)

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:collaboration_provider, request.run_id, request, self()})

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

  defmodule Echo do
    def execute(operation) do
      send(operation.backend_context.test, {:child_echo, operation})
      {:ok, %{text: "executed by " <> operation.run_id}}
    end
  end

  defmodule CatalogPublisher do
    def execute(operation) do
      send(operation.backend_context.test, {:catalog_publisher, operation, self()})

      receive do
        {:publish, update} ->
          receipt = operation.backend_context.stage_catalog.(update)
          send(operation.backend_context.test, {:catalog_staged, receipt})
          {:ok, %{text: "catalog staged"}}
      end
    end
  end

  test "active notifications checkpoint once and idle or stale notifications cannot reach followup" do
    ctx = runtime()

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:collaboration_binding, binding}
    assert_receive {:collaboration_provider, run, _, child_provider}, 1_000
    {:ok, snapshot} = MultiAgent.snapshot(ctx.manager)
    [agent] = snapshot.agents

    recipient =
      Map.take(agent, [:agent_id, :run_id, :incarnation])
      |> Map.put(:manager_id, snapshot.manager_id)

    sender = sender(ctx.binding)
    notification = %{id: "live-1", text: "live notification", metadata: %{source: "test"}}

    assert {:ok, %{status: :accepted}} =
             MultiAgent.notify_active(ctx.manager, sender, recipient, notification)

    assert {:ok, %{status: :accepted}} =
             MultiAgent.notify_active(ctx.manager, sender, recipient, notification)

    assert {:ok, %{status: :skipped_stale}} =
             MultiAgent.notify_active(
               ctx.manager,
               sender,
               %{recipient | incarnation: recipient.incarnation + 1},
               %{id: "stale-1", text: "stale notification"}
             )

    {child_provider, _result, request} = tool_request(child_provider, run, "list_agents", %{})
    assert count_messages(request, "live notification") == 1
    assert count_messages(request, "stale notification") == 0
    send(child_provider, {:events, [done()]})
    eventually(fn -> Session.status(binding.session).phase == :idle end)

    eventually(fn ->
      {:ok, s} = MultiAgent.snapshot(ctx.manager)
      hd(s.agents).status == :completed
    end)

    assert {:ok, %{status: :skipped_inactive}} =
             MultiAgent.notify_active(ctx.manager, sender, recipient, %{
               id: "idle-1",
               text: "idle notification"
             })

    refute_receive {:collaboration_provider, _, _, _}, 30

    {_root_provider, _} =
      tool(root_provider, "root", "followup_task", %{
        "target" => "/root/worker",
        "message" => "continue"
      })

    assert_receive {:collaboration_binding, rebound}
    assert rebound.run_incarnation == binding.run_incarnation + 1
    assert_receive {:collaboration_provider, _next_run, request, provider}, 1_000
    assert count_messages(request, "live notification") == 1
    assert count_messages(request, "idle notification") == 0
    assert count_messages(request, "stale notification") == 0
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(rebound.session).phase == :idle end)
    close(ctx)
  end

  test "foreign and released native stdin handles settle as rejection without touching valid commands",
       %{tmp_dir: root} do
    child_workspace = Path.join(root, "child")
    File.mkdir_p!(child_workspace)

    ctx =
      runtime(
        context: command_context(root),
        child_context: %{workspace: child_workspace},
        extra_tools: ~w(exec_command write_stdin)
      )

    {root_provider, root_job} = tool(ctx.provider, "root", "exec_command", command("ROOT"))

    {root_provider, _} =
      tool(root_provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:collaboration_binding, binding}
    assert_receive {:collaboration_provider, run, _, child_provider}, 1_000
    {child_provider, child_job} = tool(child_provider, run, "exec_command", command("CHILD"))
    assert is_integer(root_job.session_id)
    assert is_integer(child_job.session_id)

    {child_provider, rejected} =
      tool(child_provider, run, "write_stdin", %{
        "session_id" => root_job.session_id,
        "chars" => "foreign\n",
        "yield_time_ms" => 0
      })

    assert rejected.is_error
    assert Session.status(binding.session).phase == :active

    {child_provider, child_result} =
      tool(child_provider, run, "write_stdin", %{
        "session_id" => child_job.session_id,
        "chars" => "own\n",
        "yield_time_ms" => 1_000
      })

    assert child_result.output =~ "CHILD:own"
    assert child_result.status == :completed

    {child_provider, rejected} =
      tool(child_provider, run, "write_stdin", %{
        "session_id" => child_job.session_id,
        "chars" => "late\n",
        "yield_time_ms" => 0
      })

    assert rejected.is_error
    assert Session.status(binding.session).phase == :active

    {_root_provider, root_result} =
      tool(root_provider, "root", "write_stdin", %{
        "session_id" => root_job.session_id,
        "chars" => "owner\n",
        "yield_time_ms" => 1_000
      })

    assert root_result.output =~ "ROOT:owner"
    refute root_result.output =~ "foreign"
    send(child_provider, {:events, [done()]})
    eventually(fn -> Session.status(binding.session).phase == :idle end)
    close(ctx)
  end

  test "confirmed provider-only child interruption permits parent finish and fresh Session binding",
       %{tmp_dir: root} do
    ctx = runtime(context: command_context(root), extra_tools: ~w(exec_command write_stdin))

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:collaboration_binding, binding}
    assert_receive {:collaboration_provider, run, _, child_provider}, 1_000
    {child_provider, job} = tool(child_provider, run, "exec_command", command("CHILD"))
    assert is_integer(job.session_id)

    {root_provider, result} =
      tool(root_provider, "root", "interrupt_agent", %{"target" => "/root/worker"})

    assert result.status == :interrupted
    refute Process.alive?(child_provider)
    assert Session.status(binding.session).phase == :closed
    assert :ok = MultiAgent.transfer_ready(ctx.manager)
    send(root_provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.root).phase == :idle end)
    assert {:ok, new_binding} = Session.bind(ctx.root, authority("root-next", @collaboration))
    assert new_binding.run_id == "root-next"
    refute new_binding.token == ctx.binding.token
    close(ctx)
  end

  test "committed root discovery becomes executable in a real child and child publication respects ancestor grants" do
    candidates = [candidate("echo"), candidate("forbidden")]
    dynamic = start_supervised!({DynamicRuntime, candidates: candidates})

    ctx =
      runtime(
        context: %{dynamic_runtime: dynamic},
        candidates: candidates,
        extra_tools: ["tool_search"]
      )

    {root_provider, result} = tool(ctx.provider, "root", "tool_search", %{"query" => "echo"})

    assert %{tools: [%{name: "mcp::echo"}], publication: %{status: :staged}, is_error: false} =
             result

    assert Conversation.status(ctx.conversation).catalog_revision == 2

    {root_provider, result} =
      tool(root_provider, "root", "spawn_agent", %{
        "task_name" => "worker",
        "message" => "use echo"
      })

    refute result[:is_error]
    assert_receive {:collaboration_binding, binding}
    assert_receive {:collaboration_provider, run, request, provider}, 1_000
    assert Enum.any?(request.tools, &(&1.name == "mcp::echo"))
    {provider, result} = tool(provider, run, "mcp::echo", %{})
    refute result.is_error
    assert_receive {:child_echo, %{run_id: ^run, tool_name: "mcp::echo"}}, 1_000

    # The host cannot publish on behalf of the attached Conversation, even using
    # the otherwise-current Session binding.
    assert {:error, %Error{class: :forbidden}} =
             Session.adopt_catalog(binding, 1, %{
               revision: 2,
               authority: authority(run, ["mcp::forbidden"]),
               registry: %{},
               tools: []
             })

    send(provider, {:events, [call("tool_search", %{"query" => "forbidden"}), done()]})
    eventually(fn -> Session.status(binding.session).phase in [:closing, :closed] end)
    refute_receive {:child_echo, %{tool_name: "mcp::forbidden"}}, 30
    assert Process.alive?(root_provider)
    assert Conversation.status(ctx.conversation).catalog_revision == 2
    close(ctx)
  end

  test "nondefault catalog revisions reach nested delegation and root revocation fences later effects" do
    candidates = [candidate("echo")]
    dynamic = start_supervised!({DynamicRuntime, candidates: candidates})

    publisher = %{
      namespace: "host",
      name: "catalog",
      backend: CatalogPublisher,
      backend_context: %{test: self()},
      schema: %{"type" => "object", "properties" => %{}},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

    ctx =
      runtime(
        context: %{dynamic_runtime: dynamic},
        catalog_revision: 7,
        child_catalog_revision: 11,
        candidates: candidates,
        additional_contracts: [publisher],
        extra_tools: ["tool_search", "host::catalog"],
        child_tools: fn name, tools ->
          if name == "/root/worker", do: List.delete(tools, "mcp::echo"), else: tools
        end
      )

    {root_provider, _} = tool(ctx.provider, "root", "tool_search", %{"query" => "echo"})

    {root_provider, _} =
      tool(root_provider, "root", "spawn_agent", %{
        "task_name" => "worker",
        "message" => "discover"
      })

    assert_receive {:collaboration_binding, child_binding}
    assert_receive {:collaboration_provider, run, request, provider}, 1_000
    assert request.catalog_revision == 11
    refute Enum.any?(request.tools, &(&1.name == "mcp::echo"))
    {provider, result, request} = tool_request(provider, run, "tool_search", %{"query" => "echo"})
    refute result.is_error
    assert request.catalog_revision == 12

    {provider, result} =
      tool(provider, run, "spawn_agent", %{
        "task_name" => "nested",
        "message" => "use discovered echo"
      })

    refute result[:is_error]
    assert_receive {:collaboration_binding, nested_binding}
    assert_receive {:collaboration_provider, nested_run, request, nested_provider}, 1_000
    assert Enum.any?(request.tools, &(&1.name == "mcp::echo"))
    {nested_provider, result} = tool(nested_provider, nested_run, "mcp::echo", %{})
    refute result.is_error
    assert_receive {:child_echo, %{run_id: ^nested_run, tool_name: "mcp::echo"}}, 1_000

    send(root_provider, {:events, [call("host::catalog", %{}), done()]})
    assert_receive {:catalog_publisher, operation, backend}, 1_000
    current = operation.backend_context.catalog_snapshot
    revised = %{current.registry | tools: Map.delete(current.registry.tools, "mcp::echo")}

    authority =
      current.authority
      |> Map.update!(:grants, &List.delete(&1, "mcp::echo"))
      |> Map.update!(:tool_revisions, &Map.delete(&1, "mcp::echo"))

    update = %{
      run_id: "root",
      incarnation: 1,
      expected_revision: current.revision,
      publication_id: "root-revocation",
      catalog: %{
        revision: current.revision + 1,
        registry: revised,
        authority: authority,
        tools: Enum.reject(current.tools, &(&1.name == "mcp::echo"))
      }
    }

    send(backend, {:publish, update})
    assert_receive {:catalog_staged, {:ok, %{status: :staged}}}, 1_000

    assert_receive {:collaboration_provider, "root", %{catalog_revision: 9}, _root_provider},
                   1_000

    {provider, result} = tool(provider, run, "mcp::echo", %{})
    assert result.is_error
    {nested_provider, result} = tool(nested_provider, nested_run, "mcp::echo", %{})
    assert result.is_error
    refute_receive {:child_echo, _}, 30
    assert Session.status(child_binding.session).phase == :active
    assert Session.status(nested_binding.session).phase == :active
    send(provider, {:events, [done()]})
    send(nested_provider, {:events, [done()]})
    eventually(fn -> Session.status(child_binding.session).phase == :idle end)
    eventually(fn -> Session.status(nested_binding.session).phase == :idle end)
    close(ctx)
  end

  defp runtime(opts \\ []) do
    test = self()

    root =
      start_supervised!({Session, owner_pid: test, cleanup_timeout: 2_000}, id: :root_session)

    sessions =
      for name <- ["/root/worker", "/root/worker/nested"], into: %{} do
        host =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        on_exit(fn -> send(host, :stop) end)

        {name,
         start_supervised!({Session, owner_pid: host, cleanup_timeout: 1_000},
           id: {:child_session, name}
         )}
      end

    child = sessions["/root/worker"]
    table = :ets.new(:boundary_contracts, [:public])
    tools = @collaboration ++ Keyword.get(opts, :extra_tools, [])
    context = Keyword.get(opts, :context, %{})

    manager =
      start_supervised!(
        {MultiAgent,
         [
           parent_run_id: "root",
           parent_name: "/root",
           parent_authority: authority("root", tools),
           min_wait_timeout_ms: 0,
           child_options: fn _, run, parent ->
             contracts = :ets.lookup_element(table, :contracts, 2)
             child_context = Map.merge(context, Keyword.get(opts, :child_context, %{}))

             child_tools =
               Keyword.get(opts, :child_tools, fn _name, names -> names end).(
                 parent.child.name,
                 parent.authority.grants
               )

             child_opts =
               options(
                 sessions[parent.child.name],
                 run,
                 parent.child.incarnation,
                 child_tools,
                 contracts,
                 child_context,
                 test
               )
               |> Keyword.put(:catalog_revision, Keyword.get(opts, :child_catalog_revision, 1))

             send(test, {:collaboration_binding, child_opts[:session_binding]})
             {:ok, child_opts}
           end
         ]},
        id: :collaboration_manager
      )

    contracts =
      MultiAgent.contracts(:v2, manager) ++
        DynamicRuntime.contracts(context) ++
        Keyword.get(opts, :candidates, []) ++ Keyword.get(opts, :additional_contracts, [])

    :ets.insert(table, {:contracts, contracts})

    root_opts =
      options(root, "root", 1, tools, contracts, context, test)
      |> Keyword.put(:catalog_revision, Keyword.get(opts, :catalog_revision, 1))

    conversation = start_supervised!({Conversation, root_opts}, id: :root_conversation)

    on_exit(fn ->
      if Process.alive?(root), do: Session.close(root)
      if Process.alive?(manager), do: GenServer.stop(manager)
    end)

    assert {:ok, _} = Conversation.prompt(conversation, "start")
    assert_receive {:collaboration_provider, "root", _, provider}, 1_000

    %{
      root: root,
      child: child,
      manager: manager,
      conversation: conversation,
      provider: provider,
      binding: root_opts[:session_binding]
    }
  end

  defp options(session, run, incarnation, names, contracts, context, test) do
    auth = authority(run, names)

    bindings =
      Map.new(
        for contract <- contracts,
            Map.has_key?(contract, :collaboration_binding),
            contract.tool_name in names,
            do: {contract.tool_name, contract.collaboration_binding.fingerprint}
      )

    auth = if map_size(bindings) > 0, do: Map.put(auth, :tool_bindings, bindings), else: auth
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)

    context =
      Map.merge(context, %{
        resource_registry: binding.resource_registry,
        session_registry: binding.resource_registry,
        session_binding: binding,
        caller: %{run_id: run}
      })

    selected =
      Enum.filter(
        Tools.contracts(context) ++ contracts,
        &(Contract.canonical_name(&1[:namespace], &1.name) in names)
      )

    {:ok, profile} = Catalog.admit(selected, auth)

    registry = %{
      profile.registry
      | tools:
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            {name, put_in(descriptor.backend_context[:session_binding], binding)}
          end)
    }

    {:ok, store} = EphemeralStore.new(1)

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: test},
      work: 40,
      run_timeout: 15_000,
      cleanup_timeout: 2_000
    ]
  end

  defp sender(binding) do
    {:ok, owner} =
      Session.validate(binding, %{run_id: binding.run_id, incarnation: binding.run_incarnation})

    %{
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      caller: "host",
      backend_context: %{resource_owner: owner}
    }
  end

  defp close(ctx), do: assert({:ok, %{status: :confirmed}} = Session.close(ctx.root))

  defp candidate(name),
    do: %{
      namespace: "mcp",
      name: name,
      description: name,
      backend: Echo,
      backend_context: %{test: self()},
      schema: %{"type" => "object", "properties" => %{}},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

  defp authority(run, tools), do: %{caller: "host", run_id: run, grants: tools, tool_revision: 1}

  defp command(prefix),
    do: %{
      "cmd" => "read value; printf '" <> prefix <> ":%s' \"$value\"",
      "login" => false,
      "yield_time_ms" => 0
    }

  defp command_context(root) do
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    %{workspace: root, command: command}
  end

  defp tool(provider, run, name, arguments) do
    {next, result, _request} = tool_request(provider, run, name, arguments)
    {next, result}
  end

  defp tool_request(provider, run, name, arguments) do
    send(provider, {:events, [call(name, arguments), done()]})
    assert_receive {:collaboration_provider, ^run, request, next}, 7_000
    message = request.messages |> Enum.reverse() |> Enum.find(&(&1[:role] == :tool))
    {next, message.result, request}
  end

  defp count_messages(request, text),
    do:
      Enum.count(
        request.messages,
        &(is_binary(&1[:content]) and String.contains?(&1.content, text))
      )

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: name <> Integer.to_string(System.unique_integer([:positive])),
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
  defp eventually(fun, tries \\ 300)
  defp eventually(_fun, 0), do: flunk("public lifecycle did not settle")

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end
end
