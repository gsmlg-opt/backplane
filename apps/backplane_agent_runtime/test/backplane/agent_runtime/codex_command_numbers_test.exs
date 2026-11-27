defmodule Backplane.AgentRuntime.CodexCommandNumbersTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command, Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Backend, ResourceRegistry}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule WriteFailure do
    def write(command, _invocation, _job, chars) do
      send(command.server, {:write_dispatched, chars})
      {:error, Error.new(:validation, "failure returned after dispatch")}
    end
  end

  setup %{tmp_dir: root} do
    server = start_supervised!({LocalCommand, name: nil})
    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        deadline_limit: 15_000
      })

    %{
      context: %{
        workspace: root,
        command: command,
        caller: %{run_id: "command-numbers"},
        owner_pid: self(),
        session_registry: registry
      }
    }
  end

  test "integral JSON handles resume a real command and preserve the observed arguments", ctx do
    session = start_command(ctx.context)

    arguments = %{
      "session_id" => session / 1,
      "chars" => "resumed\n",
      "yield_time_ms" => 1_000.0,
      "max_output_tokens" => 100.0
    }

    operation = operation(ctx.context, "write_stdin", arguments)

    assert {:ok, %{output: "resumed", exit_code: 0, command_id: ^session}} =
             Backend.execute(operation)

    assert operation.arguments["session_id"] === session / 1
    assert operation.arguments["yield_time_ms"] === 1_000.0
  end

  test "integral zero yield does not silently select the default wait", ctx do
    assert {:ok, %{session_id: session, wall_time_seconds: elapsed}} =
             Codex.call(ctx.context, "exec_command", %{
               "cmd" => "read line; read release; printf '%s' \"$line\"",
               "login" => false,
               "yield_time_ms" => 0.0
             })

    assert elapsed < 1

    assert {:ok, %{session_id: ^session, status: :running, wall_time_seconds: elapsed}} =
             Codex.call(ctx.context, "write_stdin", %{
               "session_id" => session / 1,
               "chars" => "yielded\n",
               "yield_time_ms" => 0.0
             })

    assert elapsed < 1

    assert {:ok, %{session_id: ^session, status: :running, wall_time_seconds: elapsed}} =
             Codex.call(ctx.context, "write_stdin", %{
               "session_id" => session / 1,
               "yield_time_ms" => 0.0
             })

    assert elapsed < 1

    assert {:ok, %{exit_code: 0, output: "yielded"}} =
             Codex.call(ctx.context, "write_stdin", %{
               "session_id" => session / 1,
               "chars" => "release\n",
               "yield_time_ms" => 1_000.0
             })
  end

  test "invalid command numbers are settled before dispatch and leave the command usable", ctx do
    session = start_command(ctx.context)

    for arguments <- [
          %{},
          %{"session_id" => session + 0.25},
          %{"session_id" => 0.0},
          %{"session_id" => -1},
          %{"session_id" => "#{session}"},
          %{"session_id" => session, "yield_time_ms" => 0.25},
          %{"session_id" => session, "eof" => "true"}
        ] do
      operation = operation(ctx.context, "write_stdin", Map.put(arguments, "chars", "bad\n"))
      assert {:rejected, rejection} = Backend.execute(operation)

      assert {:ok, %{is_error: true, error: %Error{class: :validation}}} =
               result = ToolEffects.validate_rejection(rejection, operation)

      assert ToolEffects.settlement(result, %{read_only: false}) == :settled
    end

    assert {:ok, %{exit_code: 0, output: "valid"}} =
             Codex.call(ctx.context, "write_stdin", %{
               "session_id" => session,
               "chars" => "valid\n",
               "yield_time_ms" => 1_000
             })
  end

  test "fractional exec yield is rejected before creating a command", ctx do
    operation =
      operation(ctx.context, "exec_command", %{
        "cmd" => "printf unexpected > unexpected",
        "yield_time_ms" => 0.5
      })

    assert {:rejected, rejection} = Backend.execute(operation)
    assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(rejection, operation)
    refute File.exists?(Path.join(ctx.context.workspace, "unexpected"))

    assert {:ok, []} =
             ResourceRegistry.owner_status(ctx.context.session_registry, "command-numbers")
  end

  test "an error returned after stdin dispatch retains uncertain settlement", ctx do
    assert {:ok, session} =
             ResourceRegistry.register_session(
               ctx.context.session_registry,
               "command-numbers",
               %{job: %{owner_run_id: "command-numbers"}, cursor: 0}
             )

    command = %{ctx.context.command | adapter: WriteFailure, server: self()}
    context = %{ctx.context | command: command}

    operation =
      operation(context, "write_stdin", %{"session_id" => session / 1, "chars" => "sent"})

    assert {:error, %Error{class: :validation}} = result = Backend.execute(operation)
    assert_receive {:write_dispatched, "sent"}
    assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
  end

  defp start_command(context) do
    assert {:ok, %{session_id: session}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "read line; printf '%s' \"$line\"",
               "login" => false,
               "yield_time_ms" => 0
             })

    session
  end

  defp operation(context, tool, arguments) do
    %{
      run_id: "command-numbers",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: tool,
      tool_revision: 1,
      arguments: arguments,
      backend_context: %{family: :local, context: context}
    }
  end
end
