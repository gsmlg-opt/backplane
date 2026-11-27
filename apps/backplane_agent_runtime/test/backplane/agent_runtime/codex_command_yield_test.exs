defmodule Backplane.AgentRuntime.CodexCommandYieldTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @tag timeout: 45_000
  test "initial wait yields within thirty seconds and stdin finishes the same command", %{
    tmp_dir: root
  } do
    server = start_supervised!({LocalCommand, name: nil, pipe_stdin: true})
    registry = start_supervised!(ResourceRegistry)
    tasks = start_supervised!(Task.Supervisor)

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        deadline_limit: :infinity
      })

    context = %{
      workspace: root,
      command: command,
      caller: %{run_id: "command-yield"},
      owner_pid: self(),
      session_registry: registry
    }

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        Codex.call(context, "exec_command", %{
          "cmd" => "printf started; read -r answer; printf 'finished:%s' \"$answer\"",
          "login" => false,
          "yield_time_ms" => 1_800_000
        })
      end)

    assert {:ok, {:ok, %{status: :running, output: "started", session_id: session} = initial}} =
             Task.yield(task, 32_000)

    assert initial.wall_time_seconds >= 30
    assert initial.wall_time_seconds < 32

    assert {:ok, %{command_id: ^session, exit_code: 0, output: "finished:answer"} = final} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session,
               "chars" => "answer\n",
               "yield_time_ms" => 1_000
             })

    assert final.cleanup_status == :confirmed
    refute Map.has_key?(final, :session_id)
  end
end
