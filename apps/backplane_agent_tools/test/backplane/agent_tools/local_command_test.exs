defmodule Backplane.AgentTools.LocalCommandTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentTools.LocalCommand

  setup do
    {:ok, _} = LocalCommand.start_link()
    coreutils = System.get_env("COREUTILS")

    unless is_binary(coreutils) do
      raise "COREUTILS must point to the Coreutils multiplexer binary"
    end

    workspace =
      Path.join(
        System.tmp_dir!(),
        "backplane-local-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    env_path = Path.join(workspace, "env")
    printf_path = Path.join(workspace, "printf")
    sleep_path = Path.join(workspace, "sleep")
    File.ln_s!(coreutils, env_path)
    File.ln_s!(coreutils, printf_path)
    File.ln_s!(coreutils, sleep_path)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, allowed_environment: %{"BACKPLANE_TEST" => "value"}})

    %{command: command, workspace: workspace}
  end

  defp wait_for_output(command, invocation, job, cursor, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    parent = self()

    spawn_link(fn ->
      Process.sleep(50)

      send(
        parent,
        {:command_output, Command.read(command, invocation, job, cursor: cursor)}
      )
    end)

    receive do
      {:command_output, result} -> result
    after
      timeout -> Command.read(command, invocation, job, cursor: cursor)
    end
  end

  test "starts, reads bounded output, and cleans up jobs", %{
    command: command,
    workspace: workspace
  } do
    executable = Path.join(workspace, "env")

    invocation = %{
      executable: executable,
      arguments: ["printf", "%s", "hello"],
      owner_run_id: "run_1",
      workspace: workspace,
      environment: %{"BACKPLANE_TEST" => "value"}
    }

    assert {:ok, job} =
             Command.start(command, invocation, deadline_limit: 1000, output_limit: 100)

    assert job.owner_run_id == "run_1"

    deadline = System.monotonic_time(:millisecond) + 1000

    assert {:ok, %{output: ["hello"], cursor: 1}} =
             wait_for_output(command, invocation, job, 0, deadline)

    forbidden_invocation =
      Map.put(invocation, :environment, %{"BACKPLANE_TEST" => "value", "SECRET" => "leak"})

    assert {:error, %{class: :forbidden}} = Command.start(command, forbidden_invocation)

    active_invocation = %{
      executable: Path.join(workspace, "sleep"),
      arguments: ["0.2"],
      owner_run_id: "run_1",
      workspace: workspace,
      environment: %{}
    }

    assert {:ok, _running_job} = Command.start(command, active_invocation, deadline_limit: 1000)

    assert {:error, %{class: :resource_conflict}} = Command.start(command, active_invocation)

    assert :ok = Command.cancel(command, invocation)
  end
end
