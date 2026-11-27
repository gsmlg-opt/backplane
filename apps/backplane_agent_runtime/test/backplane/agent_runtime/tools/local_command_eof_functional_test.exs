defmodule Backplane.AgentRuntime.Tools.LocalCommandEofFunctionalTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand
  @moduletag :tmp_dir

  defmodule ObservedAdapter do
    def capabilities(_), do: %{stdin_close: %{pipe: true, pty: false}}
    def start(_, _, _), do: raise("unexpected start")

    def read(command, _, _, _) do
      send(command.server, :unexpected_read)
      {:error, Error.new(:execution_failure, "unexpected read")}
    end

    def cancel(_, _), do: :ok

    def write(command, _, _, _) do
      send(command.server, :unexpected_write)
      :ok
    end

    def close_stdin(command, _, _) do
      send(command.server, :unexpected_close)
      :ok
    end
  end

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
               "cmd" =>
                 "cat; printf EOF; while [ ! -f release-output ]; do sleep 0.05; done; printf FINAL",
               "yield_time_ms" => 1
             })

    id = running.session_id

    assert {:ok, after_eof} =
             Codex.call(context, "write_stdin", %{
               "session_id" => id,
               "chars" => "hello",
               "eof" => true,
               "yield_time_ms" => 0
             })

    assert after_eof.session_id == id
    File.touch!(Path.join(ctx.tmp_dir, "release-output"))

    assert {:ok, final} =
             Codex.call(context, "write_stdin", %{"session_id" => id, "yield_time_ms" => 5000})

    assert after_eof.output <> final.output == "helloEOFFINAL"
    assert final.exit_code == 0
    assert final.command_id == id
    refute Map.has_key?(final, :session_id)
    assert {:ok, []} = ResourceRegistry.owner_status(registry, "eof")
  end

  test "unsupported PTY EOF refuses nonempty bytes before any adapter write" do
    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{adapter: ObservedAdapter, server: self(), allowed_environment: %{}})

    job = %{tty: true, owner_run_id: "eof-preflight"}

    {:ok, id} =
      ResourceRegistry.register_session(registry, "eof-preflight", %{job: job, cursor: 0})

    context = %{command: command, caller: %{run_id: "eof-preflight"}, session_registry: registry}

    assert {:error, %Error{class: :unsupported_capability}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => id,
               "chars" => "must-not-send",
               "eof" => true
             })

    refute_received :unexpected_write
    refute_received :unexpected_close
    refute_received :unexpected_read
  end

  test "acknowledged empty and repeated EOF deny subsequent bytes and retain final output", ctx do
    server = start_supervised!({LocalCommand, name: nil, pipe_stdin: true})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = %{
      owner_run_id: "repeat-eof",
      workspace: ctx.tmp_dir,
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        ~s("$1"; "$2" 0.1; printf FINAL),
        "sh",
        System.find_executable("cat"),
        System.find_executable("sleep")
      ]
    }

    assert {:ok, job} = Command.start(command, invocation)
    assert :ok = Command.close_stdin(command, invocation, job)
    assert :ok = Command.close_stdin(command, invocation, job)
    assert {:error, %Error{class: :validation}} = Command.write(command, invocation, job, "late")

    assert {:ok, %{status: :completed, cleanup_status: :confirmed, output: "FINAL"}} =
             await(command, invocation, job, 200)
  end

  defp await(command, invocation, job, attempts) when attempts > 0 do
    case Command.read(command, invocation, job, cursor: 0) do
      {:ok, %{cleanup_status: :confirmed}} = result ->
        result

      {:ok, _} ->
        Process.sleep(10)
        await(command, invocation, job, attempts - 1)

      result ->
        result
    end
  end
end
