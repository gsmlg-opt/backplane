defmodule Backplane.AgentRuntime.Tools.LocalCommandCleanupTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools.LocalCommand

  import ExUnit.CaptureLog

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
    {server, command} =
      start_backend(cleanup_timeout: 500, cleanup_reconciler: controlled_reconciler(self()))

    request = ignored_term_request(workspace, "crashed-cleanup")
    {:ok, job} = Command.start(command, request, deadline_limit: 5_000)
    group_id = owned_group(server, job.port)
    on_exit(fn -> kill_group(group_id) end)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))

    assert :ok = Command.cancel(command, request)
    port = job.port

    assert_receive {:cleanup_worker, worker, ^port, token, ^group_id}, 500

    assert %{
             cleanup_token: ^token,
             cleanup_task_pid: ^worker,
             cleanup_task_ref: cleanup_ref,
             cleanup_status: :pending
           } = active_job(server, job.port)

    assert is_reference(cleanup_ref)
    assert process_running?(group_id)
    send(worker, {:crash, :injected_cleanup_crash})

    assert {:ok, failed} = wait_for_status(command, request, job, :cleanup_failed, 1_000)
    assert failed.cleanup_status == :uncertain
    assert failed.cleanup_error.class == :resource_conflict
    assert process_running?(group_id)

    send(server, {:cleanup_result, job.port, token, :ok})
    send(server, {job.port, {:exit_status, 0}})
    send(server, {job.port, {:data, {:eol, ~c"late output"}}})

    assert {:ok, ^failed} = Command.read(command, request, job, cursor: 0)
    failed_state = :sys.get_state(server)
    assert failed_state.owned_groups[job.port].process_group_id == group_id
    assert MapSet.member?(failed_state.workspaces, workspace)

    assert {:error, %{class: :resource_conflict}} =
             Command.start(command, %{request | owner_run_id: "crash-workspace-reuse"})

    later_workspace = prepare_workspace(workspace, "later")
    later = request(later_workspace, "later-owner", ["true"])
    assert {:ok, later_job} = Command.start(command, later, deadline_limit: 1_000)
    later_port = later_job.port
    later_group = owned_group(server, later_job.port)
    on_exit(fn -> kill_group(later_group) end)

    assert_receive {:cleanup_worker, later_worker, ^later_port, _later_token, ^later_group}, 500
    assert :ok = wait_until_stopped([later_group], monotonic_deadline(500))
    later_ref = active_job(server, later_job.port).cleanup_task_ref
    send(later_worker, {:return, :ok})

    assert {:ok, completed} = wait_for_status(command, later, later_job, :completed, 1_000)
    send(server, {:DOWN, later_ref, :process, later_worker, :normal})
    assert {:ok, ^completed} = Command.read(command, later, later_job, cursor: 0)
    assert Process.alive?(server)
  end

  test "watchdog fences late results and leaves another job and timer untouched", %{
    workspace: workspace
  } do
    {server, command} =
      start_backend(cleanup_timeout: 2_000, cleanup_reconciler: controlled_reconciler(self()))

    request = ignored_term_request(workspace, "stalled-cleanup")
    {:ok, job} = Command.start(command, request, deadline_limit: 5_000)
    group_id = owned_group(server, job.port)
    on_exit(fn -> kill_group(group_id) end)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))

    assert :ok = Command.cancel(command, request)
    port = job.port

    assert_receive {:cleanup_worker, worker, ^port, token, ^group_id}, 500

    %{cleanup_task_ref: cleanup_ref, cleanup_timer: cleanup_timer} =
      active_job(server, job.port)

    assert is_reference(cleanup_ref)
    assert is_reference(cleanup_timer)

    rearm_cleanup_watchdog(server, job.port, token, cleanup_ref, cleanup_timer)

    other_workspace = prepare_workspace(workspace, "watchdog-other")

    other = %{
      request(other_workspace, "other-owner", ["30"])
      | executable: Path.join(other_workspace, "sleep")
    }

    {:ok, other_job} = Command.start(command, other, deadline_limit: 5_000)
    other_group = owned_group(server, other_job.port)
    on_exit(fn -> kill_group(other_group) end)
    other_state = active_job(server, other_job.port)

    assert {:ok, failed} = wait_for_status(command, request, job, :cleanup_failed, 1_000)
    assert failed.cleanup_status == :uncertain
    refute Process.alive?(worker)

    late_error = Error.new(:resource_conflict, "late cleanup failure")
    send(server, {cleanup_ref, :ok})
    send(server, {cleanup_ref, {:error, late_error}})
    send(server, {:cleanup_result, job.port, token, :ok})
    send(server, {:cleanup_result, job.port, token, {:error, late_error}})
    send(server, {:DOWN, cleanup_ref, :process, worker, :normal})
    send(server, {:cleanup_timeout, job.port, token, cleanup_ref})

    state = :sys.get_state(server)
    assert {:ok, ^failed} = Command.read(command, request, job, cursor: 0)
    assert state.owned_groups[job.port].process_group_id == group_id
    assert state.active[other_job.port].timer == other_state.timer
    assert state.active[other_job.port].status == :running
    assert Process.read_timer(other_state.timer) > 0
    assert process_running?(other_state.process_group_id)

    assert {:error, %{class: :resource_conflict}} =
             Command.start(command, %{request | owner_run_id: "watchdog-reuse"})
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
    uncertain_group = owned_group(server, job.port)
    on_exit(fn -> kill_group(uncertain_group) end)
    wait_for_file(request.executable <> ".ready", monotonic_deadline(500))

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
             uncertain_group

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

    active_workspace = prepare_workspace(workspace, "active-descendants")
    {active_request, active_pid_file} = descendant_request(active_workspace, "active-shutdown")
    {active_server, active_command} = start_backend()
    {:ok, active_job} = Command.start(active_command, active_request, deadline_limit: 5_000)
    active_group = owned_group(active_server, active_job.port)
    on_exit(fn -> kill_group(active_group) end)
    [active_parent, active_child] = wait_for_pids(active_pid_file, monotonic_deadline(500))

    assert active_parent == active_group
    assert active_child != active_parent
    assert process_group(active_child) == active_group
    assert process_running?(active_parent)
    assert process_running?(active_child)

    GenServer.stop(active_server)
    assert :ok = wait_until_stopped([active_parent, active_child], monotonic_deadline(1_000))
    assert process_running?(unrelated_pid)

    uncertain_workspace = prepare_workspace(workspace, "uncertain-descendants")

    {uncertain_server, uncertain_command} =
      start_backend(
        cleanup_timeout: 500,
        completion_retention: 40,
        cleanup_reconciler: controlled_reconciler(self())
      )

    {uncertain_request, uncertain_pid_file} =
      descendant_request(uncertain_workspace, "uncertain-shutdown")

    {:ok, uncertain_job} =
      Command.start(uncertain_command, uncertain_request, deadline_limit: 5_000)

    uncertain_group = owned_group(uncertain_server, uncertain_job.port)
    on_exit(fn -> kill_group(uncertain_group) end)

    [uncertain_parent, uncertain_child] =
      wait_for_pids(uncertain_pid_file, monotonic_deadline(500))

    assert :ok = Command.cancel(uncertain_command, uncertain_request)
    uncertain_port = uncertain_job.port

    assert_receive {:cleanup_worker, uncertain_worker, ^uncertain_port, _token, ^uncertain_group},
                   500

    assert process_running?(uncertain_parent)
    assert process_running?(uncertain_child)
    assert uncertain_child != uncertain_parent
    assert process_group(uncertain_child) == uncertain_group
    send(uncertain_worker, {:return, {:error, Error.new(:resource_conflict, "indeterminate")}})

    assert {:ok, %{cleanup_status: :uncertain}} =
             wait_for_status(
               uncertain_command,
               uncertain_request,
               uncertain_job,
               :cleanup_failed,
               1_000
             )

    assert :ok =
             wait_until(
               fn ->
                 match?(
                   {:error, %{class: :not_found}},
                   Command.read(uncertain_command, uncertain_request, uncertain_job, cursor: 0)
                 )
               end,
               monotonic_deadline(500)
             )

    state = :sys.get_state(uncertain_server)
    assert state.owned_groups[uncertain_job.port].process_group_id == uncertain_parent
    assert MapSet.member?(state.workspaces, uncertain_workspace)
    assert process_running?(uncertain_parent)
    assert process_running?(uncertain_child)

    GenServer.stop(uncertain_server)

    assert :ok =
             wait_until_stopped([uncertain_parent, uncertain_child], monotonic_deadline(1_000))

    assert process_running?(unrelated_pid)
  end

  test "shutdown reaps a pending launcher that never receives acknowledgement", %{
    workspace: workspace
  } do
    launcher = Path.join(workspace, "pending-launcher")
    launcher_pid_file = Path.join(workspace, "pending-launcher.pid")
    payload = Path.join(workspace, "never-runs")
    payload_marker = Path.join(workspace, "payload-ran")

    File.write!(
      launcher,
      "#!/bin/sh\nprintf '%s' \"$$\" > '#{launcher_pid_file}'\nIFS= read -r _ack\n"
    )

    File.write!(payload, "#!/bin/sh\nprintf ran > '#{payload_marker}'\n")
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

    on_exit(fn ->
      if Process.alive?(caller.pid), do: Process.exit(caller.pid, :kill)
    end)

    wait_for_file(launcher_pid_file, monotonic_deadline(500))
    launcher_pid = launcher_pid_file |> File.read!() |> String.to_integer()
    port_pid = :sys.get_state(server).pending |> Map.values() |> hd() |> Map.fetch!(:launcher_pid)

    on_exit(fn ->
      kill_pid(launcher_pid)
      kill_pid(port_pid)
    end)

    GenServer.stop(server)
    assert match?({:caller_exit, _reason}, Task.await(caller, 1_000))
    assert :ok = wait_until_stopped([launcher_pid, port_pid], monotonic_deadline(1_000))
    refute File.exists?(payload_marker)
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

  test "shutdown suppresses only a confirmed already-absent group signal failure", %{
    workspace: workspace
  } do
    {server, command} =
      start_backend(
        cleanup_timeout: 500,
        cleanup_reconciler: controlled_reconciler(self())
      )

    finished = request(workspace, "absent-before-shutdown", ["true"])
    {:ok, job} = Command.start(command, finished, deadline_limit: 1_000)
    port = job.port
    group_id = owned_group(server, port)
    on_exit(fn -> kill_group(group_id) end)

    assert_receive {:cleanup_worker, worker, ^port, _token, ^group_id}, 500
    assert :ok = wait_until_stopped([group_id], monotonic_deadline(500))

    send(worker, {:return, {:error, Error.new(:resource_conflict, "probe indeterminate")}})

    assert {:ok, %{status: :cleanup_failed, cleanup_status: :uncertain}} =
             wait_for_status(command, finished, job, :cleanup_failed, 1_000)

    state = :sys.get_state(server)
    assert state.owned_groups[job.port].process_group_id == group_id
    assert MapSet.member?(state.workspaces, workspace)

    log = capture_log(fn -> GenServer.stop(server) end)
    refute log =~ "local command shutdown signal failed"
    refute log =~ "local command shutdown cleanup could not be confirmed"
  end

  test "shutdown distinguishes a post-signal absence race from a still-live signal failure", %{
    workspace: workspace
  } do
    test_pid = self()

    race_signaler = fn group_id, "-KILL" ->
      kill_group(group_id)
      result = wait_until_stopped([group_id], monotonic_deadline(500))
      send(test_pid, {:race_signal_result, result})
      {"simulated already-absent race", 1}
    end

    {race_server, race_command} =
      start_backend(
        cleanup_timeout: 500,
        cleanup_reconciler: controlled_reconciler(self()),
        shutdown_signaler: race_signaler
      )

    race_request = ignored_term_request(workspace, "shutdown-race")
    {:ok, race_job} = Command.start(race_command, race_request, deadline_limit: 5_000)
    race_group = owned_group(race_server, race_job.port)
    on_exit(fn -> kill_group(race_group) end)
    wait_for_file(race_request.executable <> ".ready", monotonic_deadline(500))
    assert :ok = Command.cancel(race_command, race_request)
    race_port = race_job.port
    assert_receive {:cleanup_worker, race_worker, ^race_port, _token, ^race_group}, 500
    send(race_worker, {:return, {:error, Error.new(:resource_conflict, "uncertain")}})

    assert {:ok, %{cleanup_status: :uncertain}} =
             wait_for_status(race_command, race_request, race_job, :cleanup_failed, 1_000)

    assert process_running?(race_group)
    race_log = capture_log(fn -> GenServer.stop(race_server) end)
    assert_receive {:race_signal_result, :ok}, 500
    refute race_log =~ "local command shutdown signal failed"
    refute race_log =~ "local command shutdown cleanup could not be confirmed"

    failure_workspace = prepare_workspace(workspace, "shutdown-failure")
    failed_signaler = fn _group_id, "-KILL" -> {"permission denied", 1} end

    {failure_server, failure_command} =
      start_backend(
        cleanup_timeout: 500,
        shutdown_timeout: 60,
        cleanup_reconciler: controlled_reconciler(self()),
        shutdown_signaler: failed_signaler
      )

    failure_request = ignored_term_request(failure_workspace, "shutdown-failure")
    {:ok, failure_job} = Command.start(failure_command, failure_request, deadline_limit: 5_000)
    failure_group = owned_group(failure_server, failure_job.port)
    on_exit(fn -> kill_group(failure_group) end)
    wait_for_file(failure_request.executable <> ".ready", monotonic_deadline(500))
    assert :ok = Command.cancel(failure_command, failure_request)
    failure_port = failure_job.port

    assert_receive {:cleanup_worker, failure_worker, ^failure_port, _token, ^failure_group},
                   500

    send(failure_worker, {:return, {:error, Error.new(:resource_conflict, "indeterminate")}})

    assert {:ok, failure_result} =
             wait_for_status(
               failure_command,
               failure_request,
               failure_job,
               :cleanup_failed,
               1_000
             )

    failure_state = :sys.get_state(failure_server)
    assert failure_result.cleanup_status == :uncertain
    assert failure_state.owned_groups[failure_job.port].process_group_id == failure_group
    assert MapSet.member?(failure_state.workspaces, failure_workspace)
    assert process_running?(failure_group)

    failure_log = capture_log(fn -> GenServer.stop(failure_server) end)
    assert failure_log =~ "local command shutdown signal failed"
    assert failure_log =~ "local command shutdown cleanup could not be confirmed"
    assert process_running?(failure_group)
  end

  test "cleanup and shutdown timeouts must be finite positive values", %{workspace: _workspace} do
    assert_invalid_start(cleanup_timeout: 0)
    assert_invalid_start(shutdown_timeout: :infinity)
    assert_invalid_start(shutdown_signaler: :invalid)
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

  defp descendant_request(workspace, owner) do
    script = Path.join(workspace, owner)
    pid_file = script <> ".pids"

    File.write!(
      script,
      "#!/bin/sh\n./sleep 30 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > \"$0.pids\"\nwait \"$child\"\n"
    )

    File.chmod!(script, 0o700)
    {%{request(workspace, owner, []) | executable: script}, pid_file}
  end

  defp controlled_reconciler(test_pid) do
    fn _owner, port, token, group_id ->
      send(test_pid, {:cleanup_worker, self(), port, token, group_id})

      receive do
        {:return, result} -> result
        {:crash, reason} -> exit(reason)
      end
    end
  end

  defp prepare_workspace(workspace, name) do
    nested = Path.join(workspace, name)
    File.mkdir_p!(nested)
    File.ln_s!(Path.join(workspace, "env"), Path.join(nested, "env"))
    File.ln_s!(Path.join(workspace, "sleep"), Path.join(nested, "sleep"))
    nested
  end

  defp wait_for_pids(path, deadline) do
    result =
      with {:ok, content} <- File.read(path),
           [parent, child] <- String.split(content),
           {parent, ""} <- Integer.parse(parent),
           {child, ""} <- Integer.parse(child) do
        {:ok, [parent, child]}
      else
        _other -> :pending
      end

    cond do
      match?({:ok, _pids}, result) ->
        elem(result, 1)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("PID file was incomplete: #{path}")

      true ->
        Process.sleep(5)
        wait_for_pids(path, deadline)
    end
  end

  defp active_job(server, port), do: :sys.get_state(server).active[port]

  defp owned_group(server, port) do
    :sys.get_state(server).owned_groups
    |> Map.fetch!(port)
    |> Map.fetch!(:process_group_id)
  end

  defp rearm_cleanup_watchdog(server, port, token, cleanup_ref, cleanup_timer) do
    :sys.replace_state(server, fn state ->
      Process.cancel_timer(cleanup_timer)
      timer = Process.send_after(server, {:cleanup_timeout, port, token, cleanup_ref}, 1)
      put_in(state.active[port].cleanup_timer, timer)
    end)

    :ok
  end

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

  defp process_group(pid) do
    {output, 0} =
      System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true)

    output |> String.trim() |> String.to_integer()
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
