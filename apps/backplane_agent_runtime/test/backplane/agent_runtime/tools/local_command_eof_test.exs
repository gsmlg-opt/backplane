defmodule Backplane.AgentRuntime.Tools.LocalCommandEofTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand
  @moduletag :tmp_dir
  @moduletag capture_log: true

  test "native pipe EOF flushes input, keeps output and stable command identity", ctx do
    server = start_supervised!({LocalCommand, name: nil, pipe_stdin: true})
    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    context = %{
      command: command,
      workspace: ctx.tmp_dir,
      caller: %{run_id: "eof"},
      session_registry: registry
    }

    assert %{stdin_close: %{pipe: true, pty: false}} = LocalCommand.capabilities(command)
    assert {:error, %Error{class: :unsupported_capability}} = Command.terminal(command)

    assert {:ok, running} =
             Codex.call(context, "exec_command", %{
               "cmd" => "cat; printf EOF; sleep 0.1; printf FINAL",
               "yield_time_ms" => 1
             })

    id = running.session_id

    assert {:ok, final} =
             Codex.call(context, "write_stdin", %{
               "session_id" => id,
               "chars" => "hello",
               "eof" => true,
               "yield_time_ms" => 1000
             })

    assert final.output == "helloEOFFINAL"
    assert final.exit_code == 0
    assert final.command_id == id
    refute Map.has_key?(final, :session_id)
    assert {:ok, []} = ResourceRegistry.owner_status(registry, "eof")
  end

  test "command primitive receives acknowledgement and denies later bytes", ctx do
    server = start_supervised!({LocalCommand, name: nil, pipe_stdin: true})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = %{
      owner_run_id: "primitive",
      workspace: ctx.tmp_dir,
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        "#{System.find_executable("cat")}; #{System.find_executable("sleep")} 0.2; printf DONE"
      ]
    }

    assert {:ok, job} = Command.start(command, invocation)
    assert :ok = Command.write(command, invocation, job, "bytes")

    assert {:error, %Error{class: :forbidden}} =
             Command.close_stdin(command, Map.put(invocation, :incarnation, 2), job)

    assert :ok = Command.close_stdin(command, invocation, job)
    assert :ok = Command.close_stdin(command, invocation, job)
    assert {:error, %Error{class: :validation}} = Command.write(command, invocation, job, "late")

    assert {:error, %Error{}} =
             Command.close_stdin(command, %{invocation | owner_run_id: "other"}, job)

    assert {:ok, result} = await(command, invocation, job, 100)
    assert result.output == "bytesDONE"
    assert result.status == :completed
    assert result.cleanup_status == :confirmed
  end

  test "pipe mode refuses an installed helper advertising only the legacy PTY protocol", ctx do
    helper = Path.join(ctx.tmp_dir, "old-helper")
    File.write!(helper, "#!/bin/sh\nprintf 'BACKPLANE_PTY 1\\n'\n")
    File.chmod!(helper, 0o700)

    assert {:error, %Error{class: :unsupported_capability}} =
             LocalCommand.start_link(name: nil, pipe_stdin: true, pty_helper_path: helper)
  end

  test "default raw pipe backend explicitly rejects half close", ctx do
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = %{
      owner_run_id: "legacy",
      workspace: ctx.tmp_dir,
      executable: System.find_executable("cat"),
      arguments: []
    }

    assert {:ok, job} = Command.start(command, invocation)

    assert {:error, %Error{class: :unsupported_capability}} =
             Command.close_stdin(command, invocation, job)

    assert :ok = Command.cancel(command, invocation)
  end

  defp await(command, invocation, job, remaining) when remaining > 0 do
    case Command.read(command, invocation, job, cursor: 0) do
      {:ok, %{status: :running}} ->
        Process.sleep(10)
        await(command, invocation, job, remaining - 1)

      {:ok, %{cleanup_status: :pending}} ->
        Process.sleep(10)
        await(command, invocation, job, remaining - 1)

      result ->
        result
    end
  end
end
