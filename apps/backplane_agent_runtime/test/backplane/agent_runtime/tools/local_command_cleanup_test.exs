defmodule Backplane.AgentRuntime.Tools.LocalCommandCleanupTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentRuntime.Tools.LocalCommand

  setup do
    coreutils = System.get_env("COREUTILS") || System.find_executable("coreutils")
    assert is_binary(coreutils), "COREUTILS must point to the Coreutils multiplexer binary"

    workspace =
      Path.join(
        System.tmp_dir!(),
        "backplane-local-command-cleanup-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.ln_s!(coreutils, Path.join(workspace, "env"))
    File.ln_s!(coreutils, Path.join(workspace, "sleep"))

    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "cleanup task crash settles uncertainty once and fences late messages", %{
    workspace: workspace
  } do
    crash = fn _owner, _port, _token, _group_id -> exit(:injected_cleanup_crash) end
    {server, command} = start_backend(cleanup_timeout: 500, cleanup_reconciler: crash)
    request = ignored_term_request(workspace, "crashed-cleanup")
    {:ok, job} = Command.start(command, request, deadline_limit: 5_000)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))
    %{process_group_id: group_id} = :sys.get_state(server).active[job.port]
    on_exit(fn -> kill_group(group_id) end)

    assert :ok = Command.cancel(command, request)
    %{cleanup_token: token} = active_job(server, job.port)

    assert {:ok, failed} = wait_for_status(command, request, job, :cleanup_failed, 1_000)
    assert failed.cleanup_status == :uncertain
    assert failed.cleanup_error.class == :resource_conflict

    send(server, {:cleanup_result, job.port, token, :ok})
    send(server, {job.port, {:exit_status, 0}})
    send(server, {job.port, {:data, {:eol, ~c"late output"}}})

    assert {:ok, ^failed} = Command.read(command, request, job, cursor: 0)
    assert :sys.get_state(server).owned_groups[job.port].process_group_id == group_id
  end

  test "stalled cleanup task reaches its finite uncertainty deadline", %{workspace: workspace} do
    test_pid = self()

    stall = fn _owner, _port, _token, _group_id ->
      send(test_pid, {:cleanup_stalled, self()})
      receive do: (:never -> :ok)
    end

    {server, command} = start_backend(cleanup_timeout: 60, cleanup_reconciler: stall)
    request = ignored_term_request(workspace, "stalled-cleanup")
    {:ok, job} = Command.start(command, request, deadline_limit: 5_000)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))
    %{process_group_id: group_id} = :sys.get_state(server).active[job.port]
    on_exit(fn -> kill_group(group_id) end)

    assert :ok = Command.cancel(command, request)
    assert_receive {:cleanup_stalled, _task_pid}, 500

    assert {:ok, %{cleanup_status: :uncertain}} =
             wait_for_status(command, request, job, :cleanup_failed, 1_000)
  end

  test "uncertain ownership outlives bounded result retention", %{workspace: workspace} do
    crash = fn _owner, _port, _token, _group_id -> exit(:injected_cleanup_crash) end

    {server, command} =
      start_backend(
        cleanup_timeout: 500,
        completion_retention: 40,
        cleanup_reconciler: crash
      )

    request = ignored_term_request(workspace, "retained-ownership")
    {:ok, job} = Command.start(command, request, deadline_limit: 5_000)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))
    uncertain = active_job(server, job.port)
    on_exit(fn -> kill_group(uncertain.process_group_id) end)

    assert :ok = Command.cancel(command, request)

    assert {:ok, %{cleanup_status: :uncertain}} =
             wait_for_status(command, request, job, :cleanup_failed, 1_000)

    assert :ok =
             wait_until(
               fn ->
                 match?(
                   {:error, %{class: :not_found}},
                   Command.read(command, request, job, cursor: 0)
                 )
               end,
               monotonic_deadline(500)
             )

    assert :sys.get_state(server).owned_groups[job.port].process_group_id ==
             uncertain.process_group_id

    assert {:error, %{class: :resource_conflict}} =
             Command.start(command, %{request | owner_run_id: "blocked-after-result-expiry"})
  end

  test "shutdown cleans active and uncertain verified groups but preserves unrelated work", %{
    workspace: workspace
  } do
    unrelated =
      Port.open(
        {:spawn_executable, Path.join(workspace, "sleep")},
        [:hide, :exit_status, {:args, ["30"]}]
      )

    {:os_pid, unrelated_pid} = Port.info(unrelated, :os_pid)

    on_exit(fn ->
      close_port(unrelated)
      kill_pid(unrelated_pid)
    end)

    {active_server, active_command} = start_backend()
    active_request = request(workspace, "active-shutdown", ["30"])
    {:ok, active_job} = Command.start(active_command, active_request, deadline_limit: 5_000)
    active_group = :sys.get_state(active_server).active[active_job.port].process_group_id
    on_exit(fn -> kill_group(active_group) end)

    GenServer.stop(active_server)
    assert :ok = wait_until_stopped([active_group], monotonic_deadline(1_000))
    assert process_running?(unrelated_pid)

    uncertain_workspace = Path.join(workspace, "uncertain")
    File.mkdir_p!(uncertain_workspace)
    File.ln_s!(Path.join(workspace, "sleep"), Path.join(uncertain_workspace, "sleep"))
    crash = fn _owner, _port, _token, _group_id -> exit(:injected_cleanup_crash) end

    {uncertain_server, uncertain_command} =
      start_backend(cleanup_timeout: 500, cleanup_reconciler: crash)

    uncertain_request = ignored_term_request(uncertain_workspace, "uncertain-shutdown")

    {:ok, uncertain_job} =
      Command.start(uncertain_command, uncertain_request, deadline_limit: 5_000)

    wait_for_file(uncertain_request.executable <> ".ready", monotonic_deadline(500))

    uncertain = active_job(uncertain_server, uncertain_job.port)
    on_exit(fn -> kill_group(uncertain.process_group_id) end)

    assert :ok = Command.cancel(uncertain_command, uncertain_request)

    assert {:ok, %{cleanup_status: :uncertain}} =
             wait_for_status(
               uncertain_command,
               uncertain_request,
               uncertain_job,
               :cleanup_failed,
               1_000
             )

    GenServer.stop(uncertain_server)
    assert :ok = wait_until_stopped([uncertain.process_group_id], monotonic_deadline(1_000))
    assert process_running?(unrelated_pid)
  end

  test "shutdown reaps a pending launcher that never receives acknowledgement", %{
    workspace: workspace
  } do
    launcher = Path.join(workspace, "pending-launcher")
    launcher_pid_file = Path.join(workspace, "pending-launcher.pid")
    payload = Path.join(workspace, "never-runs")

    File.write!(
      launcher,
      "#!/bin/sh\nprintf '%s' \"$$\" > '#{launcher_pid_file}'\nIFS= read -r _ack\n"
    )

    File.write!(payload, "#!/bin/sh\nexit 0\n")
    File.chmod!(launcher, 0o700)
    File.chmod!(payload, 0o700)

    {server, command} = start_backend(launcher_script: launcher, startup_timeout: 2_000)
    request = %{request(workspace, "pending-shutdown", []) | executable: payload}

    caller =
      Task.async(fn ->
        try do
          Command.start(command, request, deadline_limit: 3_000)
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    wait_for_file(launcher_pid_file, monotonic_deadline(500))
    launcher_pid = launcher_pid_file |> File.read!() |> String.to_integer()
    port_pid = :sys.get_state(server).pending |> Map.values() |> hd() |> Map.fetch!(:launcher_pid)

    on_exit(fn ->
      kill_pid(launcher_pid)
      kill_pid(port_pid)
      if Process.alive?(caller.pid), do: Process.exit(caller.pid, :kill)
    end)

    GenServer.stop(server)
    assert match?({:caller_exit, _reason}, Task.await(caller, 1_000))
    assert :ok = wait_until_stopped([launcher_pid, port_pid], monotonic_deadline(1_000))
  end

  test "shutdown after a confirmed exit leaves unrelated work running", %{workspace: workspace} do
    unrelated =
      Port.open(
        {:spawn_executable, Path.join(workspace, "sleep")},
        [:hide, :exit_status, {:args, ["30"]}]
      )

    {:os_pid, unrelated_pid} = Port.info(unrelated, :os_pid)

    on_exit(fn ->
      close_port(unrelated)
      kill_pid(unrelated_pid)
    end)

    {server, command} = start_backend()
    finished = request(workspace, "already-exited", ["true"])
    {:ok, job} = Command.start(command, finished, deadline_limit: 1_000)
    assert {:ok, %{exit_status: 0}} = wait_for_status(command, finished, job, :completed, 1_000)

    GenServer.stop(server)
    assert process_running?(unrelated_pid)
  end

  test "cleanup and shutdown timeouts must be finite positive values", %{workspace: _workspace} do
    assert_invalid_start(cleanup_timeout: 0)
    assert_invalid_start(shutdown_timeout: :infinity)
  end

  defp start_backend(opts \\ []) do
    {:ok, server} = LocalCommand.start_link(Keyword.put(opts, :name, nil))
    on_exit(fn -> stop_server(server) end)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, allowed_environment: %{}, server: server})

    {server, command}
  end

  defp request(workspace, owner, arguments) do
    %{
      executable: Path.join(workspace, "env"),
      arguments: arguments,
      owner_run_id: owner,
      workspace: workspace,
      environment: %{}
    }
  end

  defp ignored_term_request(workspace, owner) do
    script = Path.join(workspace, owner)

    File.write!(
      script,
      "#!/bin/sh\ntrap '' TERM\nprintf ready > \"$0.ready\"\nwhile :; do ./sleep 1; done\n"
    )

    File.chmod!(script, 0o700)
    %{request(workspace, owner, []) | executable: script}
  end

  defp active_job(server, port), do: :sys.get_state(server).active[port]

  defp wait_for_status(command, invocation, job, expected, timeout) do
    deadline = monotonic_deadline(timeout)
    wait_for_status_until(command, invocation, job, expected, deadline)
  end

  defp wait_for_status_until(command, invocation, job, expected, deadline) do
    case Command.read(command, invocation, job, cursor: 0) do
      {:ok, %{status: ^expected}} = result ->
        result

      result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          Process.sleep(10)
          wait_for_status_until(command, invocation, job, expected, deadline)
        end
    end
  end

  defp wait_for_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("file was not created: #{path}")

      true ->
        Process.sleep(5)
        wait_for_file(path, deadline)
    end
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

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        wait_until(fun, deadline)
    end
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> not String.starts_with?(String.trim(output), "Z")
      {_output, _status} -> false
    end
  end

  defp stop_server(server) do
    if Process.alive?(server), do: GenServer.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp kill_group(group_id) do
    System.cmd("kill", ["-KILL", "--", "-#{group_id}"], stderr_to_stdout: true)
    :ok
  end

  defp kill_pid(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp assert_invalid_start(opts) do
    result = LocalCommand.start_link(Keyword.put(opts, :name, nil))

    case result do
      {:ok, server} -> GenServer.stop(server)
      {:error, _reason} -> :ok
    end

    assert {:error, _reason} = result
  end

  defp monotonic_deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
