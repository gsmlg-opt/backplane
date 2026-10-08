defmodule Backplane.AgentRuntime.CodexCommandLifecycleTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Command, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand
  @moduletag :tmp_dir
  @moduletag capture_log: true

  if match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") do
    :ok
  else
    @moduletag skip: "command lifecycle requires Linux /proc"
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
            :fail -> raise "injected provider failure"
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule FaultStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :finish do
        if Map.get(context, :ack_loss, false), do: EphemeralStore.store(context.table, run, meta)
        send(context.test, {:finish_commit, self()})

        receive do
          :fail -> {:error, Error.new(:execution_failure, "injected store failure")}
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  defmodule AmbiguousCommand do
    defdelegate reserve(command, invocation), to: LocalCommand
    defdelegate acknowledge_release(command, invocation), to: LocalCommand
    defdelegate read(command, invocation, job, opts), to: LocalCommand
    defdelegate write(command, invocation, job, chars), to: LocalCommand

    def start(command, request, opts) do
      {:ok, _job} = LocalCommand.start(command, request, opts)
      {:error, Error.new(:transient_transport, "start acknowledgement was lost")}
    end

    def cancel_confirmed(_command, _invocation, _timeout),
      do: {:error, Error.new(:unknown_outcome, "backend reconciliation is unavailable")}

    def cancel(_command, _invocation), do: raise("owner-wide fallback must not run")
  end

  setup %{tmp_dir: root} do
    coreutils = System.find_executable("coreutils")
    assert is_binary(coreutils), "lifecycle tests require coreutils"
    File.ln_s!(coreutils, Path.join(root, "sleep"))
    registry = start_supervised!(ResourceRegistry)
    %{registry: registry}
  end

  test "cancellation acknowledges before a blocked resource cleanup finishes", ctx do
    %{conversation: conversation} = start_run(ctx)
    {:ok, _} = Conversation.prompt(conversation, "wait")
    assert_receive {:provider, %{run_id: owner}, _}, 3_000
    test = self()

    {:ok, _} =
      ResourceRegistry.register(ctx.registry, owner, :logical, :live,
        cleanup: fn ->
          send(test, {:cleanup_barrier, self()})

          receive do
            :release -> :ok
          end
        end
      )

    tasks = start_supervised!(Task.Supervisor)
    cancelling = Task.Supervisor.async_nolink(tasks, fn -> Conversation.cancel(conversation) end)
    assert_receive {:cleanup_barrier, cleanup}, 3_000
    on_exit(fn -> send(cleanup, :release) end)
    assert Task.yield(cancelling, 100) == {:ok, :ok}
    send(cleanup, :release)
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
  end

  test "a refused second launch preserves the first session and confirms final cleanup", ctx do
    %{conversation: conversation} = start_run(ctx)
    {:ok, _} = Conversation.prompt(conversation, "execute commands")
    assert_receive {:provider, %{run_id: owner}, provider}, 3_000

    send(
      provider,
      {:events,
       [
         tool("first", "exec_command", %{
           "cmd" => "read answer; printf 'FIRST_COMPLETE:%s' \"$answer\"",
           "login" => false,
           "yield_time_ms" => 0
         }),
         done()
       ]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    session = List.last(messages).result.session_id

    send(
      provider,
      {:events,
       [
         tool("refused", "exec_command", %{
           "cmd" => "printf SHOULD_NOT_START",
           "login" => false,
           "yield_time_ms" => 0
         }),
         done()
       ]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert List.last(messages).result.error.class == :resource_conflict
    assert List.last(messages).result.error.message == "workspace already has an active command"

    assert {:ok, [%{id: ^session, status: :active}]} =
             ResourceRegistry.owner_status(ctx.registry, owner)

    send(
      provider,
      {:events,
       [
         tool("finish-first", "write_stdin", %{
           "session_id" => session,
           "chars" => "usable\n",
           "yield_time_ms" => 1_000
         }),
         done()
       ]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert List.last(messages).result.output =~ "FIRST_COMPLETE:usable"
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert Conversation.status(conversation).run.state == :completed
    assert Conversation.status(conversation).resource_cleanup == :confirmed
    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, owner)
  end

  test "an ambiguous native launch retains invocation evidence and uncertain run cleanup", ctx do
    %{conversation: conversation} = start_run(ctx, adapter: AmbiguousCommand)
    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:agent_runtime, _, %{type: :run_cancelled, state: :unknown_outcome}}, 3_000
    refute_receive {:provider, _, _}, 100
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    status = Conversation.status(conversation)
    assert status.run.state == :unknown_outcome
    assert match?({:uncertain, _}, status.resource_cleanup)

    assert {:ok, [%{status: :failed}]} =
             ResourceRegistry.owner_status(ctx.registry, status.run.run_id)

    assert Enum.any?(pids, &running?/1)
  end

  test "native session admission refusal withdraws only the unused model-callable reservation",
       ctx do
    %{conversation: conversation, command: command} = start_run(ctx, session_capacity: 1)

    held = %{
      owner_run_id: "host-held",
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic])
    }

    assert :ok = Command.reserve(command, held)
    {:ok, _} = Conversation.prompt(conversation, "execute")
    assert_receive {:provider, %{run_id: owner}, provider}, 3_000

    send(
      provider,
      {:events,
       [
         tool("refused", "exec_command", %{
           "cmd" => "printf NEVER > forbidden",
           "login" => false,
           "yield_time_ms" => 0
         }),
         done()
       ]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert List.last(messages).result.error.class == :overloaded
    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, owner)
    refute File.exists?(Path.join(ctx.tmp_dir, "forbidden"))
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert Conversation.status(conversation).resource_cleanup == :confirmed
    assert :ok = Command.cancel_confirmed(command, held, 100)
    assert :ok = Command.acknowledge_release(command, held)
  end

  test "cancellation during initial polling kills parent and same-group descendant", ctx do
    %{conversation: conversation} = start_run(ctx)
    command(conversation, 5_000)
    pids = wait_pids(ctx.tmp_dir)
    assert :ok = Conversation.cancel(conversation)
    assert_stopped(pids)
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert Process.alive?(conversation)
  end

  test "returned sessions are cleaned on cancellation, completion and provider failure", ctx do
    for ending <- [:cancel, :complete, :fail] do
      root = Path.join(ctx.tmp_dir, Atom.to_string(ending))
      File.mkdir_p!(root)
      File.ln_s!(Path.join(ctx.tmp_dir, "sleep"), Path.join(root, "sleep"))
      %{conversation: conversation, server: server} = start_run(%{ctx | tmp_dir: root})
      command(conversation, 0)
      pids = wait_pids(root)
      assert_receive {:provider, %{messages: messages}, provider}, 3_000
      assert is_integer(List.last(messages).result.session_id)

      case ending do
        :cancel -> assert :ok = Conversation.cancel(conversation)
        :complete -> send(provider, {:events, [done()]})
        :fail -> send(provider, :fail)
      end

      assert_stopped(pids)
      eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert Process.alive?(server)
      assert Process.alive?(conversation)
      assert Conversation.status(conversation).resource_cleanup == :confirmed
    end
  end

  test "storage failure cleans owned processes without claiming durable terminal settlement",
       ctx do
    %{conversation: conversation} = start_run(ctx, fault_store: true)
    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:provider, _, provider}, 3_000
    send(provider, {:events, [done()]})
    assert_receive {:finish_commit, commit}, 3_000
    send(commit, :fail)
    assert_stopped(pids)
    eventually(fn -> Conversation.status(conversation).phase == :storage_failed end)
    refute Conversation.status(conversation).run.state == :completed
  end

  test "lost terminal acknowledgement retains storage uncertainty after OS cleanup", ctx do
    %{conversation: conversation} =
      start_run(ctx, fault_store: true, ack_loss: true, commit_timeout: 100)

    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:provider, _, provider}, 3_000
    send(provider, {:events, [done()]})
    assert_receive {:finish_commit, _commit}, 3_000
    assert_stopped(pids)
    eventually(fn -> Conversation.status(conversation).phase == :storage_failed end)
    refute Conversation.status(conversation).run.state == :completed
  end

  test "root deadline cleans a returned session", ctx do
    %{conversation: conversation} = start_run(ctx, run_timeout: 500)
    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:provider, _, _}, 3_000
    assert_stopped(pids)
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
  end

  test "unconfirmed backend cleanup retains process and unknown-outcome evidence", ctx do
    cleanup = fn _, _, _, _ ->
      {:error, Error.new(:resource_conflict, "injected cleanup uncertainty")}
    end

    %{conversation: conversation} = start_run(ctx, cleanup_reconciler: cleanup)
    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:provider, _, provider}, 3_000
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    status = Conversation.status(conversation)
    assert match?({:uncertain, _}, status.resource_cleanup)
    assert status.run.state == :unknown_outcome
    assert status.run.outcome["cleanup"]["certainty"] == "uncertain"
    assert Enum.any?(pids, &running?/1)

    assert {:ok, [_ | _] = evidence} =
             ResourceRegistry.owner_status(ctx.registry, status.run.run_id)

    assert Enum.any?(evidence, &(&1.status in [:failed, :uncertain]))
  end

  test "owner death cleans returned session despite surviving host supervisor", ctx do
    %{conversation: conversation, server: server} = start_run(ctx)
    command(conversation, 0)
    pids = wait_pids(ctx.tmp_dir)
    assert_receive {:provider, _, _}, 3_000
    Process.exit(conversation, :kill)
    assert_stopped(pids)
    assert Process.alive?(server)
  end

  test "cancellation during launcher handshake fences the later acknowledgement", ctx do
    launcher = Path.join(ctx.tmp_dir, "gated-launcher.sh")
    # The launcher's PID file is a deterministic pre-handshake barrier. The test
    # releases it only after cancellation acceptance.
    original =
      Application.app_dir(:backplane_agent_runtime, "priv/local_command_launcher.sh")
      |> File.read!()

    File.write!(
      launcher,
      "#!/bin/sh\nprintf '%s' \"$$\" > launch.pid\nwhile [ ! -f release ]; do ./sleep 0.01; done\n" <>
        original
    )

    %{conversation: conversation} =
      start_run(ctx, launcher_script: launcher, startup_timeout: 3_000)

    command(conversation, 0)
    eventually(fn -> File.exists?(Path.join(ctx.tmp_dir, "launch.pid")) end)
    pid = File.read!(Path.join(ctx.tmp_dir, "launch.pid")) |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true) end)
    assert :ok = Conversation.cancel(conversation)
    File.write!(Path.join(ctx.tmp_dir, "release"), "release")
    assert_stopped([pid])
    refute File.exists?(Path.join(ctx.tmp_dir, "parent.pid"))
  end

  defp start_run(ctx, opts \\ []) do
    id = "lifecycle-#{System.unique_integer([:positive])}"

    backend_opts =
      Keyword.take(opts, [
        :launcher_script,
        :startup_timeout,
        :cleanup_reconciler,
        :session_capacity
      ]) ++ [name: nil]

    server =
      start_supervised!(
        Supervisor.child_spec({LocalCommand, backend_opts}, id: {LocalCommand, id})
      )

    {:ok, command} =
      Command.new(%{
        adapter: Keyword.get(opts, :adapter, LocalCommand),
        server: server,
        allowed_environment: %{},
        deadline_limit: 10_000
      })

    context = %{
      workspace: ctx.tmp_dir,
      command: command,
      session_registry: ctx.registry,
      caller: %{run_id: id}
    }

    authority = %{
      run_id: id,
      caller: "host",
      grants: ["exec_command", "write_stdin"],
      tool_revision: 1
    }

    {:ok, profile} =
      Codex.profile(:pinned_local, context, authority, tools: ["exec_command", "write_stdin"])

    {:ok, table} = EphemeralStore.new(1)

    {store, storage} =
      if opts[:fault_store],
        do: {FaultStore, %{table: table, test: self(), ack_loss: opts[:ack_loss] || false}},
        else: {EphemeralStore, table}

    args = [
      run_id: id,
      provider: Provider,
      provider_context: %{test: self()},
      subscriber: self(),
      store: store,
      context: storage,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      run_timeout: Keyword.get(opts, :run_timeout, 10_000),
      commit_timeout: Keyword.get(opts, :commit_timeout, 5_000),
      cleanup_timeout: 3_000
    ]

    conversation =
      start_supervised!(Supervisor.child_spec({Conversation, args}, id: id, restart: :temporary))

    %{conversation: conversation, server: server, command: command}
  end

  defp command(conversation, yield_ms) do
    assert {:ok, _} = Conversation.prompt(conversation, "execute command")
    assert_receive {:provider, _, provider}, 3_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "command",
             name: "exec_command",
             arguments: %{
               "cmd" =>
                 "printf '%s' \"$$\" > parent.pid; ./sleep 30 & printf '%s' \"$!\" > child.pid; wait",
               "login" => false,
               "yield_time_ms" => yield_ms
             }
           }
         },
         done()
       ]}
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp tool(id, name, arguments),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}

  defp wait_pids(root) do
    paths = Enum.map(["parent.pid", "child.pid"], &Path.join(root, &1))

    eventually(fn ->
      Enum.all?(paths, fn path -> match?({:ok, text} when text != "", File.read(path)) end)
    end)

    pids = Enum.map(paths, &(File.read!(&1) |> String.to_integer()))

    on_exit(fn ->
      Enum.each(
        pids,
        &System.cmd("kill", ["-KILL", Integer.to_string(&1)], stderr_to_stdout: true)
      )
    end)

    pids
  end

  defp assert_stopped(pids), do: eventually(fn -> Enum.all?(pids, &(not running?(&1))) end)

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not Regex.match?(~r/\) [ZX] /, stat)
      {:error, :enoent} -> false
    end
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 4_000)

  defp eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "condition did not settle"

      receive do
      after
        10 -> :ok
      end

      eventually(fun, deadline)
    end
  end
end
