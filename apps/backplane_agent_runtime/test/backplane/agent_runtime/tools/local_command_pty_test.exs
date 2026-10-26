defmodule Backplane.AgentRuntime.Tools.LocalCommandPtyTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Backplane.AgentRuntime.Tools.LocalCommand.Pty

  @moduletag :tmp_dir
  @moduletag capture_log: true

  unless match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") do
    @moduletag skip: "local command PTY requires Linux /proc"
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:pty_provider, request, self()})

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

  test "optional helper is probed and dimensions are advertised only on enabled servers" do
    pipe = start_supervised!({LocalCommand, name: nil}, id: :pipe)

    pty =
      start_supervised!(
        {LocalCommand, name: nil, pty: true, terminal_rows: 33, terminal_columns: 99},
        id: :pty
      )

    assert {:error, %Error{class: :unsupported_capability}} =
             Command.terminal(%{adapter: LocalCommand, server: pipe})

    assert {:ok, %{rows: 33, columns: 99}} =
             Command.terminal(%{adapter: LocalCommand, server: pty})

    assert {:error, %Error{class: :unsupported_capability}} =
             LocalCommand.start_link(name: nil, pty: true, pty_helper_path: "/missing/pty")

    assert {:error, %Error{class: :validation}} =
             LocalCommand.start_link(name: nil, pty: true, terminal_rows: 0)
  end

  test "UTF-8 projection holds split suffixes and replaces invalid/final incomplete bytes" do
    assert {"a", <<0xE2>>} = Pty.project("a" <> <<0xE2>>, false)
    assert {"€", ""} = Pty.project(<<0xE2, 0x82, 0xAC>>, false)
    assert {"�x", ""} = Pty.project(<<0xFF, ?x>>, false)
    assert {"�", ""} = Pty.project(<<0xE2, 0x82>>, true)
  end

  test "original Codex tools use a real controlling terminal and preserve incremental bytes",
       ctx do
    server =
      start_supervised!(
        {LocalCommand, name: nil, pty: true, terminal_rows: 33, terminal_columns: 99}
      )

    context = context(server, ctx.tmp_dir)

    assert {:ok, %{session_id: session, output: output}} =
             Codex.call(context, "exec_command", %{
               "cmd" =>
                 "test -t 0 && test -t 1 && test -t 2 || exit 9; #{System.find_executable("stty")} size; printf '\\033[31mPROMPT>'; read answer; printf '%s\\n' \"$answer\"",
               "tty" => true,
               "login" => false,
               "yield_time_ms" => 100
             })

    assert output =~ "33 99\r\n"
    assert output =~ "\e[31mPROMPT>"

    assert {:ok, %{output: output, cleanup_status: :confirmed} = result} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => "PTY_INPUT\n",
               "yield_time_ms" => 1000
             })

    assert output =~ "PTY_INPUT\r\n"
    refute Map.has_key?(result, :session_id)
    assert {:ok, []} = ResourceRegistry.owner_status(context.session_registry, "pty-owner")
  end

  test "one enabled backend preserves pipe formatting and per-launch selection", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})
    context = context(server, ctx.tmp_dir)

    for tty <- [false, true] do
      assert {:ok, %{output: output, cleanup_status: :confirmed}} =
               Codex.call(context, "exec_command", %{
                 "cmd" => "printf 'one\\ntwo\\n'",
                 "tty" => tty,
                 "login" => false,
                 "yield_time_ms" => 1000
               })

      if tty, do: assert(output == "one\r\ntwo\r\n"), else: assert(output == "one\ntwo")
    end
  end

  test "split UTF-8 across polls advances only when a whole character is visible", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})
    context = context(server, ctx.tmp_dir)

    assert {:ok, %{session_id: session, output: ""}} =
             Codex.call(context, "exec_command", %{
               "cmd" =>
                 "#{System.find_executable("stty")} -echo; printf '\\342'; read first; printf '\\202\\254'; read second; printf '\\377'",
               "tty" => true,
               "login" => false,
               "yield_time_ms" => 100
             })

    assert {:ok, %{session_id: ^session, output: output}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => "\n",
               "yield_time_ms" => 100
             })

    assert output =~ "€"
    assert String.valid?(output)

    assert {:ok, %{cleanup_status: :confirmed, output: output}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => "\n",
               "yield_time_ms" => 1000
             })

    assert output =~ "�"
    refute output =~ "€"
  end

  test "explicit cancellation covers surviving interactive job-control groups", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{"PATH" => System.get_env("PATH")}
      })

    invocation = %{
      executable: System.find_executable("bash"),
      arguments: ["--noprofile", "--norc", "-i"],
      workspace: ctx.tmp_dir,
      environment: %{"PATH" => System.get_env("PATH")},
      owner_run_id: "cancel",
      owner_pid: self(),
      session_id: 12,
      incarnation: 2,
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    assert :ok = Command.reserve(command, invocation)
    assert {:ok, job} = Command.start(command, invocation)

    assert :ok =
             Command.write(
               command,
               invocation,
               job,
               "#{System.find_executable("sleep")} 30 &\necho CHILD:$!\n"
             )

    output =
      await_output(command, invocation, job, "CHILD:", System.monotonic_time(:millisecond) + 1000)

    [_, child] = Regex.run(~r/CHILD:(\d+)/, output)
    assert :ok = Command.cancel_confirmed(command, invocation, 1000)
    assert stopped?(child)
    assert :ok = Command.acknowledge_release(command, invocation)
  end

  test "broker loss finalizes an observed incomplete suffix without releasing workspace", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        output_limit: 64
      })

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        "#{System.find_executable("stty")} -echo; printf 'CHILD:%s\\n\\342\\202' \"$$\"; read input"
      ],
      workspace: ctx.tmp_dir,
      environment: %{},
      owner_run_id: "broker-loss-suffix",
      session_id: 994,
      incarnation: 1,
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    :ok = Command.reserve(command, invocation)
    {:ok, job} = Command.start(command, invocation)

    {observed, active} =
      await_held_suffix(
        server,
        command,
        invocation,
        job,
        System.monotonic_time(:millisecond) + 1000
      )

    %{broker: broker, guardian: guardian, child: child} = active.pty_identity
    assert observed.output == "CHILD:#{child}\r\n"
    assert observed.status == :running
    assert Port.info(job.port, :os_pid) == {:os_pid, broker}
    {_, 0} = System.cmd("kill", ["-KILL", to_string(broker)])

    result = await_terminal(command, invocation, job, System.monotonic_time(:millisecond) + 1000)
    await_stopped([child, guardian], System.monotonic_time(:millisecond) + 1000)

    assert result.cleanup_status == :uncertain
    assert result.cleanup_error.class == :unknown_outcome

    assert {:ok, %{output: "�", cursor: cursor}} =
             Command.read(command, invocation, job, cursor: observed.cursor)

    assert cursor == observed.cursor + 1

    assert {:ok, %{output: "", cursor: ^cursor}} =
             Command.read(command, invocation, job, cursor: cursor)

    assert result.output == observed.output <> "�"
    assert byte_size(result.output) <= 64
    completed = :sys.get_state(server).completed[job.port]
    assert completed.utf8_pending == ""
    assert completed.bytes == active.bytes
    assert completed.bytes <= 64

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(command, invocation, 1000)

    assert {:error, %Error{class: :resource_conflict}} =
             Command.start(command, %{invocation | session_id: 995})
  end

  test "confirmed completion projects a final incomplete suffix exactly once", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: ["-c", "printf 'prefix:\\342\\202'"],
      workspace: ctx.tmp_dir,
      environment: %{},
      owner_run_id: "completed-suffix",
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    {:ok, job} = Command.start(command, invocation)
    result = await_terminal(command, invocation, job, System.monotonic_time(:millisecond) + 1000)
    assert result.cleanup_status == :confirmed
    assert result.output == "prefix:�"

    assert {:ok, %{output: "", cursor: cursor}} =
             Command.read(command, invocation, job, cursor: result.cursor)

    assert cursor == result.cursor
  end

  test "helper disappearance after startup is an authenticated refusal without crashing the backend",
       ctx do
    helper = Path.join(ctx.tmp_dir, "helper")

    File.cp!(
      Application.app_dir(:backplane_agent_runtime, "priv/bin/backplane-local-command-pty"),
      helper
    )

    File.chmod!(helper, 0o755)
    server = start_supervised!({LocalCommand, name: nil, pty: true, pty_helper_path: helper})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    File.rm!(helper)

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: ["-c", "printf unreachable"],
      workspace: ctx.tmp_dir,
      environment: %{},
      owner_run_id: "missing-helper",
      session_id: 993,
      incarnation: 1,
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    :ok = Command.reserve(command, invocation)

    assert {:error, %Error{details: %{launch_status: :never_started}} = error} =
             Command.start(command, invocation)

    assert Process.alive?(server)
    assert :ok = Command.validate_refusal(command, invocation, error)
    assert :ok = Command.cancel_confirmed(command, invocation, 1000)
  end

  test "retained invalid-byte text and incomplete suffixes count against the hard cap", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        output_limit: 64
      })

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        "printf '\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377'"
      ],
      workspace: ctx.tmp_dir,
      environment: %{},
      owner_run_id: "invalid-cap",
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    {:ok, job} = Command.start(command, invocation)
    result = await_terminal(command, invocation, job, System.monotonic_time(:millisecond) + 1000)
    assert result.status == :output_limit_exceeded
    assert result.cleanup_status == :confirmed
    assert byte_size(result.output) <= 64
  end

  test "missing guardian proof pins workspace and cannot be retried into confirmation", ctx do
    server = start_supervised!({LocalCommand, name: nil, pty: true})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: ["-c", "printf 'CHILD:%s\\n' \"$PPID\"; read input"],
      workspace: ctx.tmp_dir,
      environment: %{},
      owner_run_id: "guardian-loss",
      session_id: 991,
      incarnation: 3,
      tty: true,
      terminal: %{rows: 24, columns: 80}
    }

    :ok = Command.reserve(command, invocation)
    {:ok, job} = Command.start(command, invocation)

    output =
      await_output(command, invocation, job, "CHILD:", System.monotonic_time(:millisecond) + 1000)

    [_, guardian] = Regex.run(~r/CHILD:(\d+)/, output)
    {_, 0} = System.cmd("kill", ["-KILL", guardian])
    result = await_terminal(command, invocation, job, System.monotonic_time(:millisecond) + 1000)
    assert result.cleanup_status == :uncertain
    assert result.cleanup_error.class == :unknown_outcome

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(command, invocation, 1000)

    assert {:error, %Error{class: :resource_conflict}} =
             Command.start(command, %{invocation | session_id: 992})
  end

  test "public Session close settles real PTY jobs admitted and stored by Conversation", ctx do
    backend = start_supervised!({LocalCommand, name: nil, pty: true})
    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 2000})

    authority = %{
      caller: "host",
      run_id: "pty-conversation",
      grants: ["exec_command", "write_stdin"],
      tool_revision: 1
    }

    {:ok, binding} = Session.bind(session, authority)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: backend, allowed_environment: %{}})

    {:ok, profile} =
      Codex.profile(
        :configured,
        %{
          workspace: ctx.tmp_dir,
          command: command,
          session_binding: binding,
          caller: %{run_id: authority.run_id}
        },
        authority,
        families: [:local],
        tools: authority.grants
      )

    {:ok, table} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: authority.run_id,
         incarnation: 1,
         session_binding: binding,
         store: EphemeralStore,
         context: table,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         work: 20,
         run_timeout: 10_000,
         effect_timeout: 2000,
         cleanup_timeout: 2000}
      )

    {:ok, _} = Conversation.prompt(conversation, "start terminal")
    assert_receive {:pty_provider, _, provider}, 1000
    sleep = System.find_executable("sleep")

    done = %{
      type: :response_completed,
      message: %{role: :assistant, content: "done"},
      tool_calls: [],
      usage: nil
    }

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "pty-exec",
             name: "exec_command",
             arguments: %{
               "cmd" => "set -m; #{sleep} 30 & echo CHILD:$!; read input",
               "tty" => true,
               "login" => false,
               "yield_time_ms" => 100
             }
           }
         },
         done
       ]}
    )

    assert_receive {:pty_provider, %{messages: messages}, _next}, 3000

    result =
      messages
      |> Enum.filter(&(&1[:role] == :tool and &1[:name] == "exec_command"))
      |> List.last()
      |> Map.fetch!(:result)

    assert is_integer(result.session_id)
    [_, child] = Regex.run(~r/CHILD:(\d+)/, result.output)
    assert {:ok, %{revision: revision}} = EphemeralStore.load(table, authority.run_id)
    assert revision > 1
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert stopped?(child)
    assert Process.alive?(backend)
  end

  defp context(server, workspace) do
    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{"PATH" => System.get_env("PATH")},
        deadline_limit: 10_000
      })

    %{
      workspace: workspace,
      command: command,
      session_registry: start_supervised!(ResourceRegistry),
      owner_pid: self(),
      caller: %{run_id: "pty-owner"},
      incarnation: 4
    }
  end

  defp await_output(command, invocation, job, marker, deadline) do
    {:ok, %{output: output}} = Command.read(command, invocation, job, cursor: 0)

    if Regex.match?(~r/CHILD:\d+/, output) and String.contains?(output, marker) do
      output
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(output)
      Process.sleep(10)
      await_output(command, invocation, job, marker, deadline)
    end
  end

  defp await_terminal(command, invocation, job, deadline) do
    {:ok, result} = Command.read(command, invocation, job, cursor: 0)

    if result.cleanup_status in [:confirmed, :uncertain] do
      result
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(result)
      Process.sleep(10)
      await_terminal(command, invocation, job, deadline)
    end
  end

  defp await_held_suffix(server, command, invocation, job, deadline) do
    {:ok, observed} = Command.read(command, invocation, job, cursor: 0)
    active = :sys.get_state(server).active[job.port]

    if active.utf8_pending == <<0xE2, 0x82>> and
         String.contains?(observed.output, "CHILD:") do
      {observed, active}
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect({observed, active})
      Process.sleep(10)
      await_held_suffix(server, command, invocation, job, deadline)
    end
  end

  defp await_stopped(pids, deadline) do
    unless Enum.all?(pids, &stopped?/1) do
      assert System.monotonic_time(:millisecond) < deadline, inspect(pids)
      Process.sleep(10)
      await_stopped(pids, deadline)
    end
  end

  defp stopped?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.starts_with?(["Z", "X"])
      {:error, :enoent} -> true
    end
  end
end
