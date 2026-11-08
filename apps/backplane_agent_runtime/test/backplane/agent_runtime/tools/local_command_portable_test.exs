defmodule Backplane.AgentRuntime.Tools.LocalCommandPortableTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Backplane.AgentRuntime.Tools.LocalCommand.Platform

  @moduletag :tmp_dir
  @moduletag capture_log: true

  test "run returns output and confirms retirement", ctx do
    {command, _server} = backend()
    invocation = invocation(ctx.tmp_dir, "printf 'portable\\n'")
    assert {:ok, job} = Command.start(command, invocation)
    result = await(command, invocation, job)
    assert result.output == ["portable"]
    assert result.status == :completed
    assert result.cleanup_status == :confirmed
    assert :ok = Command.cancel_confirmed(command, invocation, 1_500)
    assert :ok = Command.acknowledge_release(command, invocation)
  end

  test "deadline and output budget both settle the process group", ctx do
    for {script, opts, expected, index} <- [
          {"while :; do :; done", [deadline_limit: 100], :deadline_exceeded, 1},
          {"while :; do printf '1234567890\\n'; done", [output_limit: 64], :output_limit_exceeded,
           2}
        ] do
      workspace = Path.join(ctx.tmp_dir, to_string(index))
      File.mkdir_p!(workspace)
      {command, _server} = backend(index)
      invocation = invocation(workspace, script)
      assert {:ok, job} = Command.start(command, invocation, opts)
      result = await(command, invocation, job)
      assert result.status == expected
      assert result.cleanup_status == :confirmed
    end
  end

  test "cancellation preserves separate concurrent groups", ctx do
    {command, server} = backend()

    jobs =
      for index <- 1..4 do
        workspace = Path.join(ctx.tmp_dir, to_string(index))
        File.mkdir_p!(workspace)
        invocation = invocation(workspace, "IFS= read -r line")
        assert {:ok, job} = Command.start(command, invocation, deadline_limit: 10_000)
        {invocation, job}
      end

    [{first, first_job} | rest] = jobs
    assert :ok = Command.cancel_confirmed(command, first, 1_500)

    assert {:ok, %{cleanup_status: :confirmed}} =
             Command.read(command, first, first_job, cursor: 0)

    for {invocation, job} <- rest do
      assert {:ok, %{status: :running}} = Command.read(command, invocation, job, cursor: 0)
      assert :ok = Command.cancel_confirmed(command, invocation, 1_500)
    end

    assert :sys.get_state(server).owned_groups == %{}
  end

  test "cleanup finds a descendant after its leader exits", ctx do
    {command, _server} = backend()
    sleep = System.find_executable("sleep")
    # The descendant retains stdout and the group after the shell exits.
    invocation = invocation(ctx.tmp_dir, "'#{sleep}' 30 & exit 0")
    assert {:ok, job} = Command.start(command, invocation, deadline_limit: 300)
    result = await(command, invocation, job)
    assert result.cleanup_status == :confirmed
    assert result.status in [:completed, :deadline_exceeded]
  end

  test "owner death confirms cleanup and backend shutdown removes its groups", ctx do
    {command, server} = backend()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    first = invocation(ctx.tmp_dir, "IFS= read -r line") |> Map.put(:owner_pid, owner)
    assert {:ok, first_job} = Command.start(command, first, deadline_limit: 10_000)
    send(owner, :stop)
    assert await(command, first, first_job).cleanup_status == :confirmed

    second = invocation(ctx.tmp_dir, "IFS= read -r line")
    assert {:ok, _job} = Command.start(command, second, deadline_limit: 10_000)
    paths = :sys.get_state(server).bootstrap_paths

    [group] =
      :sys.get_state(server).owned_groups |> Map.values() |> Enum.map(& &1.process_group_id)

    assert {:ok, true} = Platform.group_exists?(group, paths)
    assert :ok = GenServer.stop(server)
    assert {:ok, false} = Platform.group_exists?(group, paths)
  end

  test "pending launch cancellation observes the wrapper exit", ctx do
    launcher = Path.join(ctx.tmp_dir, "pending-launcher")
    File.write!(launcher, "#!/bin/sh\nIFS= read -r acknowledgement\n")
    File.chmod!(launcher, 0o700)
    {command, server} = backend(:pending, launcher_script: launcher, startup_timeout: 2_000)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    invocation = invocation(ctx.tmp_dir, "printf NEVER") |> Map.put(:owner_pid, owner)
    task = Task.async(fn -> Command.start(command, invocation, deadline_limit: 5_000) end)
    await_pending(server, 100)
    send(owner, :stop)
    assert {:error, %Error{class: :cancelled}} = Task.await(task, 1_000)
    assert :ok = Command.cancel_confirmed(command, invocation, 1_500)
  end

  test "native process probes reject malformed or failed evidence", ctx do
    helper = Path.join(ctx.tmp_dir, "untrusted-probe")
    File.write!(helper, "#!/bin/sh\nprintf 'absent\\n'\nexit 1\n")
    File.chmod!(helper, 0o700)
    paths = %{session_helper: helper}
    assert {:error, :unverified_process_probe} = Platform.group_exists?(42, paths)
    assert Platform.present_or_uncertain?(42, paths)
    assert {:error, :unverified_identity} = Platform.identity(42, paths)
    File.rm!(helper)
    assert Platform.present_or_uncertain?(42, paths)
  end

  test "unavailable macOS helper reports its build command" do
    if :os.type() == {:unix, :darwin} do
      assert {:error, %Error{class: :unsupported_capability, message: message}} =
               LocalCommand.start_link(name: nil, session_helper_path: "/nonexistent/helper")

      assert message =~ "mix backplane.command.build"
    end
  end

  defp backend(id \\ :default, opts \\ []) do
    server =
      start_supervised!(
        Supervisor.child_spec({LocalCommand, Keyword.put(opts, :name, nil)}, id: id)
      )

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    {command, server}
  end

  defp await_pending(_server, 0), do: flunk("launcher did not become pending")

  defp await_pending(server, attempts) do
    if map_size(:sys.get_state(server).pending) == 0 do
      Process.sleep(10)
      await_pending(server, attempts - 1)
    end
  end

  defp invocation(workspace, script) do
    %{
      owner_run_id: "portable-#{System.unique_integer([:positive, :monotonic])}",
      owner_pid: self(),
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic]),
      executable: System.find_executable("sh"),
      arguments: ["-c", script],
      workspace: workspace,
      environment: %{}
    }
  end

  defp await(command, invocation, job, attempts \\ 200)
  defp await(_command, _invocation, _job, 0), do: flunk("command did not settle")

  defp await(command, invocation, job, attempts) do
    assert {:ok, result} = Command.read(command, invocation, job, cursor: 0)

    if result.status in [:running, :settling, :cancelling] or result.cleanup_status == :pending do
      Process.sleep(10)
      await(command, invocation, job, attempts - 1)
    else
      result
    end
  end
end
