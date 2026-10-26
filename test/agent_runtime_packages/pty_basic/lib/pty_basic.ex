defmodule PtyBasic do
  @moduledoc false
  alias Backplane.AgentRuntime.{Codex, Command}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  def verify! do
    {:ok, backend} =
      LocalCommand.start_link(name: nil, pty: true, terminal_rows: 31, terminal_columns: 97)

    {:ok, registry} = ResourceRegistry.start_link()

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: backend, allowed_environment: %{}})

    {:ok, %{rows: 31, columns: 97}} = Command.terminal(command)

    directory =
      Path.join(System.tmp_dir!(), "backplane-pty-consumer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    context = %{
      workspace: directory,
      command: command,
      session_registry: registry,
      owner_pid: self(),
      caller: %{run_id: "pty-consumer"},
      incarnation: 1
    }

    try do
      stty = System.find_executable("stty") || raise "stty is required for native acceptance"

      {:ok, %{output: output, session_id: session}} =
        Codex.call(context, "exec_command", %{
          "cmd" =>
            "test -t 0 && test -t 1 && test -t 2 || exit 9; #{stty} size; printf 'PROMPT>'; read answer; printf '%s\\n' \"$answer\"",
          "tty" => true,
          "login" => false,
          "yield_time_ms" => 100
        })

      true = String.contains?(output, "31 97\r\n") and String.contains?(output, "PROMPT>")

      {:ok, %{output: output, cleanup_status: :confirmed}} =
        Codex.call(context, "write_stdin", %{
          "session_id" => session,
          "chars" => "PACKAGE_PTY\n",
          "yield_time_ms" => 1000
        })

      true = String.contains?(output, "PACKAGE_PTY\r\n")
      {:ok, []} = ResourceRegistry.owner_status(registry, "pty-consumer")
      IO.puts("PTY package consumer: PASS (#{:erlang.system_info(:system_architecture)})")
    after
      GenServer.stop(backend)
      GenServer.stop(registry)
      File.rm_rf!(directory)
    end
  end
end
