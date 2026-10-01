defmodule Backplane.AgentRuntime.Tools.LocalCommandOwnerCancelTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  if match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") and
       is_binary(System.get_env("COREUTILS") || System.find_executable("coreutils")) do
    :ok
  else
    @moduletag skip: "owner cancellation requires Linux and coreutils"
  end

  setup %{tmp_dir: workspace} do
    server =
      start_supervised!({LocalCommand, name: nil, receipt_capacity: 1, session_capacity: 8})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    %{server: server, command: command, workspace: workspace}
  end

  test "owner cancellation fences a reserved session through receipt eviction", ctx do
    other = identity("other")
    cancelled = identity("cancelled")
    assert :ok = Command.reserve(ctx.command, other)
    assert :ok = Command.reserve(ctx.command, cancelled)

    assert :ok = Command.cancel(ctx.command, cancelled)
    assert :ok = Command.cancel(ctx.command, cancelled)
    assert :confirmed = owner_status(ctx.server, "cancelled")

    late = request(ctx.workspace, cancelled, "late")
    assert {:error, %Error{class: :cancelled}} = Command.start(ctx.command, late)
    refute File.exists?(Path.join(ctx.workspace, "late"))
    assert :confirmed = session_status(ctx.server, cancelled)
    assert :ok = Command.acknowledge_release(ctx.command, cancelled)
    assert {:error, %Error{class: :cancelled}} = Command.start(ctx.command, late)

    churn = identity("churn")
    assert :ok = Command.reserve(ctx.command, churn)
    assert :ok = Command.cancel(ctx.command, churn)
    assert :ok = Command.acknowledge_release(ctx.command, churn)
    assert :sys.get_state(ctx.server).expired_session_floor >= cancelled.session_id

    assert :ok = Command.cancel(ctx.command, cancelled)
    assert {:ok, other_job} = Command.start(ctx.command, request(ctx.workspace, other, "other"))
    assert {:ok, _} = Command.read(ctx.command, other, other_job, cursor: 0)
    eventually(fn -> File.exists?(Path.join(ctx.workspace, "other")) end)
    assert :ok = Command.cancel_confirmed(ctx.command, other, 1_000)
    assert :ok = Command.acknowledge_release(ctx.command, other)

    assert {:error, %Error{class: :cancelled}} = Command.start(ctx.command, late)
    refute File.exists?(Path.join(ctx.workspace, "late"))
    assert map_size(:sys.get_state(ctx.server).session_obligations) == 0
  end

  test "one owner cancellation fences reserved, launching, and active work", ctx do
    launcher = Path.join(ctx.workspace, "barrier-launcher")
    barrier = Path.join(ctx.workspace, "block-launch")
    pending_pid_file = Path.join(ctx.workspace, "pending.pid")

    real_launcher =
      Application.app_dir(:backplane_agent_runtime, "priv/local_command_launcher.sh")

    File.write!(launcher, """
    #!/bin/sh
    if [ -f '#{barrier}' ]; then
      printf '%s' "$$" > '#{pending_pid_file}'
      IFS= read -r _ack
      exit 125
    fi
    exec /bin/sh '#{real_launcher}' "$@"
    """)

    File.chmod!(launcher, 0o700)

    server =
      start_supervised!(
        {LocalCommand, name: nil, launcher_script: launcher, startup_timeout: 2_000},
        id: :mixed_owner_server
      )

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    active = identity("mixed")
    pending = identity("mixed")
    reserved = identity("mixed")
    other = identity("other-mixed")
    for id <- [active, pending, reserved, other], do: assert(:ok = Command.reserve(command, id))

    active_workspace = Path.join(ctx.workspace, "active")
    pending_workspace = Path.join(ctx.workspace, "pending")
    other_workspace = Path.join(ctx.workspace, "other")
    for path <- [active_workspace, pending_workspace, other_workspace], do: File.mkdir_p!(path)

    active_request =
      Map.merge(request(active_workspace, active, "should-not-run"), %{
        arguments: ["-c", "read answer; printf ran > should-not-run"]
      })

    assert {:ok, active_job} = Command.start(command, active_request, deadline_limit: 5_000)
    active_pid = :sys.get_state(server).active[active_job.port].process_group_id
    File.write!(barrier, "block")

    pending_task =
      Task.async(fn ->
        Command.start(command, request(pending_workspace, pending, "pending-ran"),
          deadline_limit: 3_000
        )
      end)

    on_exit(fn ->
      if Process.alive?(pending_task.pid), do: Process.exit(pending_task.pid, :kill)
    end)

    eventually(fn -> File.exists?(pending_pid_file) end)
    pending_pid = pending_pid_file |> File.read!() |> String.to_integer()

    assert :ok = Command.cancel(command, active)
    assert {:error, %Error{class: :cancelled}} = Task.await(pending_task, 1_000)

    assert {:error, %Error{class: :cancelled}} =
             Command.start(command, request(ctx.workspace, reserved, "reserved-ran"))

    eventually(fn -> owner_status(server, "mixed") == :confirmed end)
    assert :confirmed = session_status(server, reserved)
    assert :confirmed = session_status(server, pending)
    assert :confirmed = session_status(server, active)
    refute File.exists?("/proc/#{active_pid}")
    refute File.exists?("/proc/#{pending_pid}")
    refute File.exists?(Path.join(ctx.workspace, "reserved-ran"))
    refute File.exists?(Path.join(pending_workspace, "pending-ran"))
    refute File.exists?(Path.join(active_workspace, "should-not-run"))

    File.rm!(barrier)

    assert {:ok, other_job} =
             Command.start(command, request(other_workspace, other, "other-ran"))

    assert {:ok, _} = Command.read(command, other, other_job, cursor: 0)
    eventually(fn -> File.exists?(Path.join(other_workspace, "other-ran")) end)
    assert :ok = Command.cancel_confirmed(command, other, 1_000)
  end

  defp identity(owner) do
    %{
      owner_run_id: owner,
      owner_pid: self(),
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic])
    }
  end

  defp request(workspace, identity, marker) do
    Map.merge(identity, %{
      executable: "/bin/sh",
      arguments: ["-c", "printf ran > #{marker}"],
      workspace: workspace,
      environment: %{}
    })
  end

  defp owner_status(server, owner), do: GenServer.call(server, {:owner_cleanup_status, owner})

  defp session_status(server, identity),
    do: GenServer.call(server, {:session_cleanup_status, identity})

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 1_000)

  defp eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not settle")

      true ->
        Process.sleep(5)
        eventually(fun, deadline)
    end
  end
end
