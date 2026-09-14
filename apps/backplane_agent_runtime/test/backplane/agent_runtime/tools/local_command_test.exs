defmodule Backplane.AgentRuntime.Tools.LocalCommandTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentRuntime.Tools.LocalCommand

  setup do
    {:ok, _} = LocalCommand.start_link()
    coreutils = System.get_env("COREUTILS") || System.find_executable("coreutils")

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
    child_path = Path.join(workspace, "spawn-child")
    File.ln_s!(coreutils, env_path)
    File.ln_s!(coreutils, printf_path)
    File.ln_s!(coreutils, sleep_path)

    File.write!(child_path, """
    #!/bin/sh
    "$1" 30 &
    child=$!
    printf '%s %s\n' "$$" "$child"
    wait "$child"
    """)

    File.chmod!(child_path, 0o700)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, allowed_environment: %{"BACKPLANE_TEST" => "value"}})

    %{command: command, workspace: workspace, child_path: child_path, sleep_path: sleep_path}
  end

  defp wait_until_stopped(pids, deadline) do
    running = Enum.filter(pids, &process_running?/1)

    cond do
      running == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, running}

      true ->
        Process.sleep(10)
        wait_until_stopped(running, deadline)
    end
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> not String.starts_with?(String.trim(output), "Z")
      {_output, _status} -> false
    end
  end

  defp wait_for_output(command, invocation, job, cursor, deadline) do
    case Command.read(command, invocation, job, cursor: cursor) do
      {:ok, %{output: []}} = result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          Process.sleep(10)
          wait_for_output(command, invocation, job, cursor, deadline)
        end

      result ->
        result
    end
  end

  defp wait_for_status(command, invocation, job, status, deadline) do
    case Command.read(command, invocation, job, cursor: 0) do
      {:ok, %{status: ^status}} = result ->
        result

      result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          Process.sleep(10)
          wait_for_status(command, invocation, job, status, deadline)
        end
    end
  end

  defp restart_backend(opts) do
    GenServer.stop(LocalCommand)
    {:ok, _pid} = LocalCommand.start_link(opts)
  end

  defp wait_for_pending_port(deadline) do
    state = :sys.get_state(LocalCommand)

    case Map.keys(state.pending) do
      [port] ->
        port

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("local command launcher did not enter pending state")
        else
          Process.sleep(10)
          wait_for_pending_port(deadline)
        end
    end
  end

  defp invocation(workspace, executable, owner_run_id, arguments \\ []) do
    %{
      executable: executable,
      arguments: arguments,
      owner_run_id: owner_run_id,
      workspace: workspace,
      environment: %{}
    }
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

  test "cancellation stops the owned command and its descendant", %{
    command: command,
    workspace: workspace,
    child_path: child_path,
    sleep_path: sleep_path
  } do
    invocation = %{
      executable: child_path,
      arguments: [sleep_path],
      owner_run_id: "run_descendants",
      workspace: workspace,
      environment: %{}
    }

    assert {:ok, job} =
             Command.start(command, invocation, deadline_limit: 5_000, output_limit: 100)

    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:ok, %{output: [process_ids]}} =
             wait_for_output(command, invocation, job, 0, deadline)

    [parent_pid, child_pid] = process_ids |> String.split() |> Enum.map(&String.to_integer/1)

    assert process_running?(parent_pid)
    assert process_running?(child_pid)
    assert :ok = Command.cancel(command, invocation)
    cleanup_deadline = System.monotonic_time(:millisecond) + 1_000
    assert :ok = wait_until_stopped([parent_pid, child_pid], cleanup_deadline)
  end

  test "launcher timeout closes the launcher without executing the payload", %{
    command: command,
    workspace: workspace
  } do
    launcher = Path.join(workspace, "silent-launcher")
    launcher_pid_file = Path.join(workspace, "launcher.pid")
    marker = Path.join(workspace, "payload-ran")
    payload = Path.join(workspace, "payload")

    File.write!(
      launcher,
      "#!/bin/sh\nprintf '%s' \"$$\" > '#{launcher_pid_file}'\nIFS= read -r _ack\n"
    )

    File.write!(payload, "#!/bin/sh\nprintf ran > '#{marker}'\n")
    File.chmod!(launcher, 0o700)
    File.chmod!(payload, 0o700)
    restart_backend(launcher_script: launcher, startup_timeout: 50)

    request = invocation(workspace, payload, "timeout")

    task =
      Task.async(fn -> Command.start(command, request, deadline_limit: 500) end)

    port = wait_for_pending_port(System.monotonic_time(:millisecond) + 500)
    {:os_pid, port_launcher_pid} = Port.info(port, :os_pid)
    assert {:error, %{class: :timeout}} = Task.await(task, 1_000)

    wrapper_pids =
      case File.read(launcher_pid_file) do
        {:ok, pid} -> [String.to_integer(pid)]
        {:error, :enoent} -> []
      end

    assert :ok =
             wait_until_stopped(
               [port_launcher_pid | wrapper_pids],
               System.monotonic_time(:millisecond) + 1_000
             )

    refute File.exists?(marker)
  end

  test "pending cancellation fails the start and cannot acknowledge the launcher", %{
    command: command,
    workspace: workspace
  } do
    launcher = Path.join(workspace, "cancelled-launcher")
    marker = Path.join(workspace, "payload-ran")
    payload = Path.join(workspace, "payload")

    File.write!(launcher, "#!/bin/sh\nIFS= read -r _ack\n")
    File.write!(payload, "#!/bin/sh\nprintf ran > '#{marker}'\n")
    File.chmod!(launcher, 0o700)
    File.chmod!(payload, 0o700)
    restart_backend(launcher_script: launcher, startup_timeout: 1_000)
    request = invocation(workspace, payload, "cancel-pending")
    task = Task.async(fn -> Command.start(command, request, deadline_limit: 2_000) end)
    port = wait_for_pending_port(System.monotonic_time(:millisecond) + 500)
    {:os_pid, launcher_pid} = Port.info(port, :os_pid)

    assert :ok = Command.cancel(command, request)
    assert {:error, %{class: :cancelled}} = Task.await(task, 1_000)
    assert :ok = wait_until_stopped([launcher_pid], System.monotonic_time(:millisecond) + 1_000)
    assert %{} = :sys.get_state(LocalCommand).pending

    send(LocalCommand, {port, {:data, {:eol, ~c"late handshake"}}})
    send(LocalCommand, {port, {:exit_status, 125}})
    send(LocalCommand, {port, :closed})
    assert %{} = :sys.get_state(LocalCommand).pending
    assert Process.alive?(Process.whereis(LocalCommand))
    refute File.exists?(marker)
  end

  test "malformed launcher handshake never acknowledges or executes the payload", %{
    command: command,
    workspace: workspace
  } do
    launcher = Path.join(workspace, "malformed-launcher")
    launcher_pid_file = Path.join(workspace, "launcher.pid")
    marker = Path.join(workspace, "payload-ran")
    payload = Path.join(workspace, "payload")

    File.write!(launcher, """
    #!/bin/sh
    printf '%s' "$$" > '#{launcher_pid_file}'
    printf 'WRONG %s %s\n' "$1" "$$"
    if IFS= read -r _ack; then exec "$2"; fi
    """)

    File.write!(payload, "#!/bin/sh\nprintf ran > '#{marker}'\n")
    File.chmod!(launcher, 0o700)
    File.chmod!(payload, 0o700)
    restart_backend(launcher_script: launcher, startup_timeout: 500)

    assert {:error, %{class: :execution_failure}} =
             Command.start(command, invocation(workspace, payload, "malformed"),
               deadline_limit: 500
             )

    launcher_pid = launcher_pid_file |> File.read!() |> String.to_integer()
    assert :ok = wait_until_stopped([launcher_pid], System.monotonic_time(:millisecond) + 1_000)
    refute File.exists?(marker)
  end

  test "arguments are passed literally and inherited environment is removed", %{
    command: command,
    workspace: workspace
  } do
    marker = Path.join(workspace, "not-created")
    literal = "spaces $(touch #{marker})"
    printf = Path.join(workspace, "printf")

    request = invocation(workspace, printf, "literal", ["%s", literal])
    assert {:ok, job} = Command.start(command, request, deadline_limit: 1_000)

    assert {:ok, %{output: [^literal]}} =
             wait_for_output(
               command,
               request,
               job,
               0,
               System.monotonic_time(:millisecond) + 1_000
             )

    refute File.exists?(marker)

    sentinel = "BACKPLANE_INHERITED_SENTINEL_#{System.unique_integer([:positive])}"
    System.put_env(sentinel, "secret")
    on_exit(fn -> System.delete_env(sentinel) end)
    env = Path.join(workspace, "env")
    env_request = invocation(workspace, env, "environment")
    assert {:ok, env_job} = Command.start(command, env_request, deadline_limit: 1_000)

    assert {:ok, %{output: output}} =
             wait_for_output(
               command,
               env_request,
               env_job,
               0,
               System.monotonic_time(:millisecond) + 1_000
             )

    refute Enum.any?(output, &String.starts_with?(&1, sentinel <> "="))
  end

  test "output and deadline limits terminate commands", %{
    command: command,
    workspace: workspace
  } do
    printf_request = invocation(workspace, Path.join(workspace, "printf"), "output", ["12345"])

    assert {:ok, output_job} =
             Command.start(command, printf_request, deadline_limit: 1_000, output_limit: 4)

    assert {:ok, %{status: :output_limit_exceeded, output_limit_exceeded?: true}} =
             wait_for_status(
               command,
               printf_request,
               output_job,
               :output_limit_exceeded,
               System.monotonic_time(:millisecond) + 1_000
             )

    sleep_request = invocation(workspace, Path.join(workspace, "sleep"), "deadline", ["30"])
    assert {:ok, deadline_job} = Command.start(command, sleep_request, deadline_limit: 50)

    assert {:ok, %{status: :deadline_exceeded}} =
             wait_for_status(
               command,
               sleep_request,
               deadline_job,
               :deadline_exceeded,
               System.monotonic_time(:millisecond) + 1_000
             )
  end

  test "cancellation is scoped to the invocation owner", %{
    command: command,
    workspace: workspace,
    sleep_path: sleep_path
  } do
    other_workspace = Path.join(workspace, "other")
    File.mkdir_p!(other_workspace)
    first = invocation(workspace, sleep_path, "first-owner", ["30"])
    second = invocation(other_workspace, sleep_path, "second-owner", ["30"])
    assert {:ok, first_job} = Command.start(command, first, deadline_limit: 5_000)
    assert {:ok, second_job} = Command.start(command, second, deadline_limit: 5_000)
    {:os_pid, first_launcher} = Port.info(first_job.port, :os_pid)
    {:os_pid, second_launcher} = Port.info(second_job.port, :os_pid)

    assert :ok = Command.cancel(command, first)
    assert :ok = wait_until_stopped([first_launcher], System.monotonic_time(:millisecond) + 1_000)
    assert process_running?(second_launcher)

    assert :ok = Command.cancel(command, second)

    assert :ok =
             wait_until_stopped([second_launcher], System.monotonic_time(:millisecond) + 1_000)
  end
end
