defmodule Backplane.AgentRuntime.CodexCommandPtyTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule NativePtyCommand do
    def capabilities(_command),
      do: %{pty: %{verified: true, platforms: [{:unix, :linux}]}}

    defdelegate reserve(command, invocation), to: LocalCommand
    defdelegate acknowledge_release(command, invocation), to: LocalCommand
    defdelegate validate_refusal(command, invocation, error), to: LocalCommand
    defdelegate cancel_confirmed(command, invocation, timeout), to: LocalCommand
    defdelegate cancel(command, invocation), to: LocalCommand
    defdelegate read(command, invocation, job, opts), to: LocalCommand
    defdelegate write(command, invocation, job, chars), to: LocalCommand

    def start(command, %{tty: true, terminal: terminal} = request, opts) do
      helper = Path.expand("../../support/native_pty.py", __DIR__)

      request = %{
        request
        | executable: System.find_executable("python3"),
          arguments:
            [
              helper,
              Integer.to_string(terminal.rows),
              Integer.to_string(terminal.columns),
              request.executable
            ] ++ request.arguments
      }

      LocalCommand.start(command, request, opts)
    end
  end

  defmodule UnsupportedPtyCommand do
    def capabilities(_command),
      do: %{pty: %{verified: false, platforms: [:os.type()]}}
  end

  defmodule OtherPlatformPtyCommand do
    def capabilities(_command),
      do: %{pty: %{verified: true, platforms: [{:unsupported, :platform}]}}
  end

  defmodule CustomDimensionsPtyCommand do
    def capabilities(_command),
      do: %{pty: %{verified: true, platforms: [:os.type()], rows: 33, columns: 99}}
  end

  defmodule InvalidDimensionsPtyCommand do
    def capabilities(_command),
      do: %{pty: %{verified: true, platforms: [:os.type()], rows: 0, columns: 80}}
  end

  test "PTY requires a verified capability for the current platform before reservation", ctx do
    registry = start_supervised!(ResourceRegistry)

    for adapter <- [
          LocalCommand,
          UnsupportedPtyCommand,
          OtherPlatformPtyCommand,
          InvalidDimensionsPtyCommand
        ] do
      {:ok, command} = Command.new(%{adapter: adapter, allowed_environment: %{}})

      context = %{
        workspace: ctx.tmp_dir,
        command: command,
        caller: %{run_id: "unsupported"},
        session_registry: registry
      }

      assert {:error, %Error{class: :unsupported_capability}} =
               Codex.call(context, "exec_command", %{"cmd" => "cat", "tty" => true})

      assert {:ok, []} = ResourceRegistry.owner_status(registry, "unsupported")
    end
  end

  test "host dimensions override the bounded 80 by 24 defaults" do
    assert {:ok, %{rows: 24, columns: 80}} = Command.terminal(%{adapter: NativePtyCommand})

    assert {:ok, %{rows: 33, columns: 99}} =
             Command.terminal(%{adapter: CustomDimensionsPtyCommand})
  end

  @tag native_pty: true
  test "native host PTY exposes dimensions, incremental input, control characters and cleanup",
       ctx do
    assert {:unix, :linux} == :os.type()
    assert is_binary(System.find_executable("python3")), "native PTY regression requires Python 3"
    coreutils = System.find_executable("coreutils")
    assert is_binary(coreutils), "native PTY regression requires coreutils"
    File.ln_s!(coreutils, Path.join(ctx.tmp_dir, "stty"))
    File.ln_s!(coreutils, Path.join(ctx.tmp_dir, "cat"))

    server = start_supervised!({LocalCommand, name: nil})
    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{
        adapter: NativePtyCommand,
        server: server,
        allowed_environment: %{},
        deadline_limit: 10_000
      })

    context = %{
      workspace: ctx.tmp_dir,
      command: command,
      session_registry: registry,
      owner_pid: self(),
      caller: %{run_id: "native-pty"},
      incarnation: 4
    }

    assert {:ok, %{session_id: session, output: output}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "./stty size; printf 'READY\\n'; ./cat",
               "tty" => true,
               "login" => false,
               "yield_time_ms" => 300
             })

    assert output =~ "24 80"
    assert output =~ "READY"
    assert is_integer(session)

    assert {:error, %Error{class: :resource_conflict}} =
             Codex.call(%{context | incarnation: 5}, "write_stdin", %{
               "session_id" => session,
               "chars" => "wrong\n"
             })

    assert {:error, %Error{class: :forbidden}} =
             Codex.call(%{context | caller: %{run_id: "other"}}, "write_stdin", %{
               "session_id" => session,
               "chars" => "wrong\n"
             })

    assert {:ok, %{output: output, session_id: ^session}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => "PTY_INPUT\n",
               "yield_time_ms" => 100
             })

    assert output =~ "PTY_INPUT"
    group = :sys.get_state(server).active |> Map.values() |> hd() |> Map.fetch!(:process_group_id)

    assert {:ok, %{cleanup_status: :confirmed} = result} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => <<3>>,
               "yield_time_ms" => 1_000
             })

    refute Map.has_key?(result, :session_id)
    assert {:ok, []} = ResourceRegistry.owner_status(registry, "native-pty")

    assert {_, status} =
             System.cmd(coreutils, ["kill", "-0", "--", "-#{group}"], stderr_to_stdout: true)

    assert status != 0
  end
end
