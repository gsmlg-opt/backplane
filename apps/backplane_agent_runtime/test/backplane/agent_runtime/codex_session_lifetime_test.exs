defmodule Backplane.AgentRuntime.CodexSessionLifetimeTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Command, Conversation, EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Backend, MultiAgent, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, context.role, request, self()})

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

  defmodule FinishBarrierStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :finish do
        send(context.test, {:finish_barrier, self()})

        receive do
          :fail -> {:error, Error.new(:execution_failure, "finish acknowledgement rejected")}
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  setup do
    session =
      start_supervised!(
        Supervisor.child_spec({Session, owner_pid: self(), cleanup_timeout: 3_000},
          restart: :temporary
        )
      )

    %{session: session}
  end

  test "normal stop removes the complete owned tree after confirmed close", ctx do
    assert {:ok, binding} = Session.bind(ctx.session, authority("normal-stop", []))
    assert {:ok, %{status: :confirmed} = receipt} = Session.close(ctx.session)
    assert Session.status(ctx.session).phase == :closed
    assert {:ok, ^receipt} = Session.close(ctx.session)
    assert Process.alive?(binding.resource_registry)

    assert_owned_tree_stops(ctx.session, binding.resource_registry)
  end

  test "normal stop bounds teardown when the closed registry cannot answer" do
    session =
      start_supervised!(
        Supervisor.child_spec({Session, owner_pid: self(), cleanup_timeout: 50},
          id: :stalled_session,
          restart: :temporary
        )
      )

    assert {:ok, binding} = Session.bind(session, authority("stalled-registry", []))
    assert {:ok, %{status: :confirmed}} = Session.close(session)

    # Unlike :sys.suspend/1, this also blocks the system stop request.
    assert :erlang.suspend_process(binding.resource_registry)
    assert_owned_tree_stops(session, binding.resource_registry)
  end

  test "normal stop reconciles resources once and preserves borrowed infrastructure", ctx do
    borrowed_registry = start_supervised!(ResourceRegistry)
    borrowed_supervisor = start_supervised!(Task.Supervisor)
    test = self()

    {:ok, borrowed_worker} =
      Task.Supervisor.start_child(borrowed_supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    assert {:ok, borrowed_handle} =
             ResourceRegistry.register(borrowed_registry, "foreign-owner", :logical, :borrowed)

    assert {:ok, binding} = Session.bind(ctx.session, authority("direct-stop", []))

    assert {:ok, _} =
             ResourceRegistry.register(
               binding.resource_registry,
               binding.owner_id,
               :logical,
               %{
                 registry: borrowed_registry,
                 supervisor: borrowed_supervisor,
                 worker: borrowed_worker
               },
               owner_pid: ctx.session,
               cleanup: fn ->
                 send(test, :direct_stop_cleaned)
                 :ok
               end
             )

    assert_owned_tree_stops(ctx.session, binding.resource_registry)
    assert_receive :direct_stop_cleaned
    refute_receive :direct_stop_cleaned
    assert Process.alive?(borrowed_registry)
    assert Process.alive?(borrowed_supervisor)
    assert Process.alive?(borrowed_worker)

    assert {:ok, :borrowed} =
             ResourceRegistry.fetch(borrowed_registry, borrowed_handle, "foreign-owner")
  end

  test "a completed turn retains a real Code Mode cell until close and normal stop", ctx do
    a = start_turn(ctx.session, "retained-cell", %{workspace: ctx.tmp_dir}, ["exec"])
    {:ok, _} = Conversation.prompt(a.pid, "retain a cell")
    assert_receive {:provider, :root, %{run_id: "retained-cell"}, provider}, 3_000

    {provider, %{status: :yielded}} =
      call_tool(provider, "retained-cell", "exec", """
      // @exec: {"yield_time_ms":10}
      await new Promise(resolve => setTimeout(resolve, 60000));
      return "finished";
      """)

    registry = a.binding.resource_registry
    assert {:ok, workers} = ResourceRegistry.worker_supervisor(registry)
    [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    {:os_pid, os_pid} = :sys.get_state(worker).port |> Port.info(:os_pid)
    worker_monitor = Process.monitor(worker)

    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)
    assert Conversation.status(a.pid).run.state == :completed
    assert Session.status(ctx.session).phase == :idle
    assert Process.alive?(worker)

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert {:ok, []} = ResourceRegistry.owner_status(registry, a.binding.owner_id)
    assert DynamicSupervisor.which_children(workers) == []

    assert {_, exit_status} =
             System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert exit_status != 0
    assert_owned_tree_stops(ctx.session, registry)
  end

  test "A naturally completes; B uses its command, yielded cell and child with fresh authority and budget",
       ctx do
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    test = self()

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "A",
         parent_name: "/root",
         parent_authority: authority("A", ["exec_command", "exec", "spawn_agent"]),
         child_options: fn _request, run, _parent ->
           {:ok, table} = EphemeralStore.new(1)

           {:ok,
            [
              run_id: run,
              store: EphemeralStore,
              context: table,
              provider: Provider,
              provider_context: %{test: test, role: :child},
              registry: %ToolRegistry{},
              tools: [],
              authority: authority(run, []),
              work: 10,
              run_timeout: 10_000
            ]}
         end,
         min_wait_timeout_ms: 0}
      )

    context = %{workspace: ctx.tmp_dir, command: command, collaboration_runtime: runtime}

    a =
      start_turn(ctx.session, "A", context, ["exec_command", "exec", "spawn_agent"],
        incarnation: 3
      )

    {:ok, _} = Conversation.prompt(a.pid, "turn A")
    assert_receive {:provider, :root, %{run_id: "A"}, provider_a}, 3_000

    {provider_a, command_result} =
      call_tool(provider_a, "A", "exec_command", %{
        "cmd" =>
          "read first; printf 'FIRST:%s\\n' \"$first\"; read second; printf 'SECOND:%s\\n' \"$second\"",
        "login" => false,
        "yield_time_ms" => 0
      })

    session_id = command_result.session_id

    code = """
    // @exec: {"yield_time_ms":10}
    await new Promise(resolve => setTimeout(resolve, 250));
    return await codex.tool('write_stdin', {session_id:#{session_id},chars:"cell\\n",yield_time_ms:1000});
    """

    {provider_a, cell_result} = call_tool(provider_a, "A", "exec", code)
    assert cell_result.status == :yielded
    cell = cell_result.cell_id

    {provider_a, %{task_name: child}} =
      call_tool(provider_a, "A", "spawn_agent", %{
        "task_name" => "child",
        "message" => "remain available"
      })

    assert_receive {:provider, :child, %{run_id: child_run_a}, child_provider_a}, 3_000

    send(provider_a, {:events, [done()]})
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)
    assert Conversation.status(a.pid).run.state == :completed
    assert Session.status(ctx.session).phase == :idle

    assert {:ok, [_command, _cell]} =
             ResourceRegistry.owner_status(a.binding.resource_registry, a.binding.owner_id)

    Process.sleep(300)

    b =
      start_turn(
        ctx.session,
        "B",
        context,
        ["write_stdin", "wait", "followup_task", "wait_agent"],
        incarnation: 4
      )

    assert Conversation.status(b.pid).run.execution_budget.used == 0
    assert Conversation.status(b.pid).run.execution_budget.root_run_id == "B"
    assert Conversation.status(b.pid).catalog_revision == 1

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(a.binding, %{run_id: "A", incarnation: 3})

    old_descriptor = a.profile.registry.tools["exec_command"]

    assert {:error, %Error{class: :forbidden}} =
             Backend.execute(%{
               run_id: "A",
               incarnation: 3,
               tool_name: "exec_command",
               backend_context: old_descriptor.backend_context,
               arguments: %{"cmd" => "printf stale > forbidden", "login" => false}
             })

    refute File.exists?(Path.join(ctx.tmp_dir, "forbidden"))

    {:ok, _} = Conversation.prompt(b.pid, "turn B")
    assert_receive {:provider, :root, %{run_id: "B"}, provider_b}, 3_000

    {provider_b, %{output: output, session_id: ^session_id}} =
      call_tool(provider_b, "B", "write_stdin", %{
        "session_id" => session_id,
        "chars" => "host\n",
        "yield_time_ms" => 100
      })

    assert output =~ "FIRST:host"

    {provider_b, resumed} =
      call_tool(provider_b, "B", "wait", %{"cell_id" => cell, "yield_time_ms" => 1_000})

    assert resumed.status == :completed
    assert resumed.value["output"] =~ "SECOND:cell"

    assert_receive {:agent_runtime, "B",
                    %{
                      type: :tool_started,
                      invocation: %{
                        tool_name: "write_stdin",
                        catalog_revision: 1,
                        tool_revision: 1
                      }
                    }},
                   3_000

    send(child_provider_a, {:events, [done()]})
    {provider_b, _} = call_tool(provider_b, "B", "wait_agent", %{"timeout_ms" => 1_000})

    {provider_b, %{accepted: true}} =
      call_tool(provider_b, "B", "followup_task", %{
        "target" => child,
        "message" => "turn B followup"
      })

    assert_receive {:provider, :child, %{run_id: child_run_b}, child_provider_b}, 3_000
    assert child_run_b != child_run_a
    assert :sys.get_state(runtime).agents[child].name == child
    send(child_provider_b, {:events, [done()]})
    {provider_b, _} = call_tool(provider_b, "B", "wait_agent", %{"timeout_ms" => 1_000})
    send(provider_b, {:events, [done()]})
    eventually(fn -> Conversation.status(b.pid).phase == :terminal end)
    assert Conversation.status(b.pid).run.state == :completed
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert :sys.get_state(runtime).agents[child].closure == :confirmed
    assert_owned_tree_stops(ctx.session, a.binding.resource_registry)
    assert Process.alive?(server)
    assert Process.alive?(runtime)
  end

  test "bindings reject foreign sessions, stale incarnations, reused run ids and journal restoration",
       ctx do
    a = start_turn(ctx.session, "A", %{}, ["clock::curr_time"])

    other =
      start_supervised!(Supervisor.child_spec({Session, owner_pid: self()}, id: :other_session))

    assert {:ok, foreign} = Session.bind(other, authority("foreign", []))
    refute foreign.owner_id == a.binding.owner_id
    refute foreign.incarnation == a.binding.incarnation

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(%{a.binding | session: other}, %{run_id: "A", incarnation: 1})

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(a.binding, %{run_id: "A", incarnation: 2})

    assert {:error, %Error{class: :forbidden}} = Session.close(%{a.binding | token: make_ref()})

    assert {:error, %Error{class: :forbidden}} =
             Conversation.start_link(
               run_id: "A",
               run: Conversation.status(a.pid).run,
               session_binding: a.binding
             )

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert {:error, %Error{}} = Session.bind(ctx.session, authority("A", []))
    assert {:ok, %{status: :confirmed}} = Session.close(other)
  end

  test "public profile and binding validation return errors for malformed host inputs", ctx do
    assert {:error, %Error{class: :validation}} = Codex.profile(:pinned_local, nil, %{})
    assert {:error, %Error{class: :validation}} = Codex.profile(:pinned_local, %{}, nil)
    assert {:error, %Error{class: :validation}} = Session.bind(ctx.session, nil)
    assert {:error, %Error{class: :validation}} = Session.bind(ctx.session, %{}, nil)
    assert Session.status(ctx.session).phase == :idle
  end

  test "partial collaboration attachment closes admission and only its own runtimes", ctx do
    runtimes =
      for id <- [:first_runtime, :foreign_runtime] do
        start_supervised!(
          Supervisor.child_spec(
            {MultiAgent,
             parent_run_id: "A",
             parent_name: "/root",
             parent_authority: authority("A", []),
             child_options: fn _, _, _ -> {:error, Error.new(:forbidden, "unused")} end},
            id: id
          )
        )
      end

    [first, foreign] = runtimes
    foreign_binding = %{owner_id: "foreign", incarnation: 9, run_id: "foreign-A"}
    assert :ok = MultiAgent.rebind_parent(foreign, foreign_binding, authority("foreign-A", []))
    assert {:ok, binding} = Session.bind(ctx.session, authority("A", []))

    registry = %ToolRegistry{
      tools: %{
        "a" => %{backend_context: %{family: :collaboration, runtime: first}},
        "b" => %{backend_context: %{family: :collaboration, runtime: foreign}}
      }
    }

    assert {:error, %Error{class: :forbidden}} =
             Session.attach(binding, %{registry: registry, authority: authority("A", [])})

    assert {:error, %Error{}} = Session.bind(ctx.session, authority("B", []))
    eventually(fn -> Session.status(ctx.session).phase == :closed end)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert :sys.get_state(first).session_closed
    refute :sys.get_state(foreign).session_closed
    assert :sys.get_state(foreign).parent_binding == foreign_binding
  end

  test "run fencing timeout still fences resource admission and attempts cleanup", ctx do
    session =
      start_supervised!(
        Supervisor.child_spec({Session, owner_pid: self(), cleanup_timeout: 200},
          id: :short_session
        )
      )

    a = start_turn(session, "suspended-A", %{}, ["clock::curr_time"])
    registry = a.binding.resource_registry
    owner = a.binding.owner_id
    test = self()

    assert {:ok, handle} =
             ResourceRegistry.register(registry, owner, :logical, :evidence,
               owner_pid: session,
               incarnation: a.binding.incarnation,
               cleanup: fn ->
                 send(test, :timeout_cleanup_attempted)
                 :ok
               end
             )

    :ok = :sys.suspend(a.pid)

    on_exit(fn ->
      if Process.alive?(a.pid), do: :sys.resume(a.pid)
    end)

    closer = Task.async(fn -> Session.close(session) end)
    eventually(fn -> Session.status(session).phase == :closing end)

    assert {:error, %Error{}} = ResourceRegistry.register(registry, owner, :logical, :late)
    assert {:error, %Error{}} = ResourceRegistry.register_session(registry, owner, :late)

    assert {:error, %Error{}} =
             ResourceRegistry.store_code_state(registry, handle, owner, "late", 1)

    assert_receive :timeout_cleanup_attempted, 1_000

    assert {:error, %Error{class: :unknown_outcome, details: details}} = Task.await(closer, 1_000)
    assert match?({:error, %Error{class: :unknown_outcome}}, details.fencing)
    assert {:ok, []} = ResourceRegistry.owner_status(registry, owner)
    assert {:error, %Error{}} = Session.bind(session, authority("B", []))
    :ok = :sys.resume(a.pid)
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)
    assert Conversation.status(a.pid).run.state == :unknown_outcome
    assert {:error, %Error{class: :unknown_outcome}} = Session.close(session)
    assert Session.status(ctx.session).phase == :idle
  end

  test "current root authority narrows future child admission within a bound run", ctx do
    test = self()
    initial = authority("A", ["spawn_agent", "exec_command"])

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "A",
         parent_name: "/root",
         parent_authority: initial,
         child_options: fn _, run, parent ->
           send(test, {:child_parent_authority, parent.authority})
           {:ok, [authority: authority(run, ["exec_command"])]}
         end}
      )

    assert {:ok, binding} = Session.bind(ctx.session, initial)
    assert :ok = MultiAgent.rebind_parent(runtime, binding, initial)

    assert {:error, %Error{class: :forbidden}} =
             MultiAgent.call(%{
               backend_context: %{
                 runtime: runtime,
                 profile: :v2,
                 resource_owner: %{owner_id: binding.owner_id, incarnation: binding.incarnation}
               },
               run_id: "A",
               incarnation: binding.run_incarnation,
               effective_authority: authority("A", ["spawn_agent", "unadmitted"]),
               tool_name: "spawn_agent",
               arguments: %{"task_name" => "child", "message" => "narrowed"}
             })

    assert_receive {:child_parent_authority, %{grants: ["spawn_agent"]}}
    assert :sys.get_state(runtime).agents == %{}
    assert :ok = MultiAgent.close_session(runtime)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "failed finish acknowledgement never exposes retained resources to B", ctx do
    a = start_turn(ctx.session, "A", %{}, ["clock::curr_time"], finish_barrier: true)
    {:ok, _} = Conversation.prompt(a.pid, "finish")
    assert_receive {:provider, :root, %{run_id: "A"}, provider}, 3_000
    send(provider, {:events, [done()]})
    assert_receive {:finish_barrier, store}, 3_000
    assert Session.status(ctx.session).phase == :detaching

    assert {:error, %Error{class: :resource_conflict}} =
             Session.bind(ctx.session, authority("B", []))

    send(store, :fail)
    eventually(fn -> Conversation.status(a.pid).phase == :storage_failed end)
    assert Session.status(ctx.session).phase == :closed
    assert {:error, %Error{}} = Session.bind(ctx.session, authority("B", []))
  end

  test "uncertain cleanup blocks detachment and preserves close evidence", ctx do
    a = start_turn(ctx.session, "A", %{}, ["clock::curr_time"])
    registry = a.binding.resource_registry
    owner = a.binding.owner_id

    assert {:ok, handle} =
             ResourceRegistry.register(registry, owner, :logical, :evidence,
               owner_pid: ctx.session,
               incarnation: a.binding.incarnation,
               cleanup: fn ->
                 {:error, Error.new(:unknown_outcome, "injected uncertain cleanup")}
               end
             )

    assert {:error, %Error{}} = ResourceRegistry.release(registry, handle, owner)
    {:ok, _} = Conversation.prompt(a.pid, "finish")
    assert_receive {:provider, :root, %{run_id: "A"}, provider}, 3_000
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)
    assert Conversation.status(a.pid).run.state == :unknown_outcome
    assert match?({:uncertain, _}, Conversation.status(a.pid).resource_cleanup)
    assert {:ok, [%{status: :failed}]} = ResourceRegistry.owner_status(registry, owner)
    assert {:error, %Error{class: :unknown_outcome}} = Session.close(ctx.session)
    assert {:error, %Error{}} = Session.bind(ctx.session, authority("B", []))
    assert_owned_tree_stops(ctx.session, registry)
  end

  test "explicit session close fences the active run and confirms native process cleanup", ctx do
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    a =
      start_turn(ctx.session, "A", %{workspace: ctx.tmp_dir, command: command}, ["exec_command"])

    {:ok, _} = Conversation.prompt(a.pid, "run")
    assert_receive {:provider, :root, %{run_id: "A"}, provider}, 3_000

    {_provider, _result} =
      call_tool(provider, "A", "exec_command", %{
        "cmd" => "read input",
        "login" => false,
        "yield_time_ms" => 0
      })

    group = :sys.get_state(server).active |> Map.values() |> hd() |> Map.fetch!(:process_group_id)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)

    assert {:ok, []} =
             ResourceRegistry.owner_status(a.binding.resource_registry, a.binding.owner_id)

    assert {_, status} = System.cmd("kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true)
    assert status != 0
    assert {:error, %Error{}} = Session.bind(ctx.session, authority("B", []))
  end

  test "explicit run cancellation closes the session rather than transferring resources", ctx do
    a = start_turn(ctx.session, "A", %{}, ["clock::curr_time"])
    {:ok, _} = Conversation.prompt(a.pid, "wait")
    assert_receive {:provider, :root, %{run_id: "A"}, _}, 3_000
    assert :ok = Conversation.cancel(a.pid)
    eventually(fn -> Conversation.status(a.pid).phase == :terminal end)
    assert Session.status(ctx.session).phase == :closed
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert {:error, %Error{}} = Session.bind(ctx.session, authority("B", []))
    assert_owned_tree_stops(ctx.session, a.binding.resource_registry)
  end

  test "host owner death closes a supervised session and kills its native process group", ctx do
    host =
      spawn(fn ->
        receive do
          :exit -> :ok
        end
      end)

    session =
      start_supervised!(
        Supervisor.child_spec({Session, owner_pid: host, cleanup_timeout: 3_000},
          id: :host_session,
          restart: :temporary
        )
      )

    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    a =
      start_turn(session, "host-A", %{workspace: ctx.tmp_dir, command: command}, ["exec_command"])

    {:ok, _} = Conversation.prompt(a.pid, "run")
    assert_receive {:provider, :root, %{run_id: "host-A"}, provider}, 3_000

    {_provider, _result} =
      call_tool(provider, "host-A", "exec_command", %{
        "cmd" => "read input",
        "login" => false,
        "yield_time_ms" => 0
      })

    group = :sys.get_state(server).active |> Map.values() |> hd() |> Map.fetch!(:process_group_id)
    send(host, :exit)
    eventually(fn -> Session.status(session).phase == :closed end)
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert {_, status} = System.cmd("kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true)
    assert status != 0
    assert_owned_tree_stops(session, a.binding.resource_registry)
    assert Process.alive?(server)
  end

  defp start_turn(session, run, context, tools, opts \\ []) do
    authority = authority(run, tools)

    {:ok, binding} =
      Session.bind(session, authority, incarnation: Keyword.get(opts, :incarnation, 1))

    context = Map.merge(context, %{session_binding: binding, caller: %{run_id: run}})

    {:ok, profile} =
      Codex.profile(:configured, context, authority,
        families:
          [:local, :code_mode] ++
            if(context[:collaboration_runtime], do: [:collaboration_v2], else: []),
        tools: tools
      )

    {:ok, table} = EphemeralStore.new(1)

    {store, storage} =
      if opts[:finish_barrier],
        do: {FinishBarrierStore, %{test: self(), table: table}},
        else: {EphemeralStore, table}

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Conversation,
           run_id: run,
           incarnation: binding.run_incarnation,
           session_binding: binding,
           store: store,
           context: storage,
           provider: Provider,
           provider_context: %{test: self(), role: :root},
           subscriber: self(),
           registry: profile.registry,
           tools: profile.tools,
           authority: profile.authority,
           work: 20,
           run_timeout: 15_000,
           effect_timeout: 5_000,
           cleanup_timeout: 3_000},
          id: run
        )
      )

    Process.put({:session_conversation, run}, pid)
    %{pid: pid, binding: binding, profile: profile}
  end

  defp authority(run, tools), do: %{caller: "host", run_id: run, grants: tools, tool_revision: 1}

  defp assert_owned_tree_stops(session, registry) do
    supervisor = :sys.get_state(session).supervisor
    {:links, children} = Process.info(registry, :links)
    owned = Enum.uniq([session, registry, supervisor | children -- [session]])
    monitors = Enum.map(owned, &{&1, Process.monitor(&1)})

    # Ensure an assertion failure on the unfixed version does not leak its children.
    on_exit(fn ->
      for pid <- owned, Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end)

    assert :ok = GenServer.stop(session, :normal)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      refute Process.alive?(pid)
    end
  end

  defp done,
    do: %{
      type: :response_completed,
      message: %{role: :assistant, content: "done"},
      tool_calls: [],
      usage: nil
    }

  defp call_tool(provider, run, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: name, name: name, arguments: arguments}},
         done()
       ]}
    )

    receive do
      {:provider, :root, %{run_id: ^run, messages: messages}, next} ->
        result =
          messages
          |> Enum.filter(&(&1[:role] == :tool and &1[:name] == name))
          |> List.last()
          |> Map.fetch!(:result)

        {next, result}
    after
      5_000 ->
        status = Conversation.status(Process.get({:session_conversation, run}))

        flunk(
          "#{run} #{name} did not continue: #{inspect(Map.take(status, [:phase, :error, :resource_cleanup]))}"
        )
    end
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: flunk("session lifecycle did not settle")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
