defmodule Backplane.AgentRuntime.Tools.LocalCommandReconciliationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  if match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") and
       is_binary(System.get_env("COREUTILS") || System.find_executable("coreutils")) do
    :ok
  else
    @moduletag skip: "command reconciliation requires Linux and coreutils"
  end

  setup %{tmp_dir: workspace} do
    server =
      start_supervised!(
        {LocalCommand, name: nil, completion_retention: 30_000, cleanup_timeout: 1_000}
      )

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    attempts = start_supervised!({Agent, fn -> %{} end})
    default_reconciler = :sys.get_state(server).cleanup_reconciler
    test_pid = self()

    :sys.replace_state(server, fn state ->
      reconciler = fn owner, port, token, group ->
        attempt =
          Agent.get_and_update(attempts, fn counts ->
            count = Map.get(counts, group, 0)
            {count, Map.put(counts, group, count + 1)}
          end)

        send(test_pid, {:cleanup_attempt, self(), port, token, group, attempt})

        receive do
          :continue ->
            if attempt == 0,
              do: {:error, Error.new(:resource_conflict, "injected first cleanup failure")},
              else: default_reconciler.(owner, port, token, group)
        end
      end

      %{state | cleanup_reconciler: reconciler}
    end)

    %{server: server, command: command, workspace: workspace}
  end

  test "verified retry updates retained output cleanup status for the exact session", ctx do
    first = identity("same-owner")
    first_workspace = workspace(ctx.workspace, "first")
    request = command_request(first_workspace, first)
    assert {:ok, job} = Command.start(ctx.command, request, deadline_limit: 5_000)
    eventually(fn -> match?({:ok, %{output: [_ | _]}}, read(ctx.command, request, job)) end)
    group = :sys.get_state(ctx.server).active[job.port].process_group_id

    assert :ok = Command.cancel(ctx.command, first)
    assert_receive {:cleanup_attempt, worker, port, token, ^group, 0}, 1_000
    assert port == job.port
    first_ref = :sys.get_state(ctx.server).active[job.port].cleanup_task_ref
    send(worker, :continue)

    eventually(fn ->
      match?({:ok, %{cleanup_status: :uncertain}}, read(ctx.command, request, job))
    end)

    {:ok, before_retry} = read(ctx.command, request, job)
    assert before_retry.status == :cleanup_failed
    assert before_retry.cleanup_error.class == :resource_conflict
    assert :uncertain = session_status(ctx.server, first)
    assert :uncertain = owner_status(ctx.server, "same-owner")
    assert File.exists?("/proc/#{group}")

    retry = Task.async(fn -> Command.cancel_confirmed(ctx.command, first, 2_000) end)

    assert_receive {:cleanup_attempt, retry_worker, {:session, session_id}, retry_token, ^group,
                    1},
                   1_000

    assert session_id == first.session_id
    send(retry_worker, :continue)
    assert :ok = Task.await(retry, 3_000)

    assert :confirmed = session_status(ctx.server, first)
    assert :confirmed = owner_status(ctx.server, "same-owner")
    assert :ok = Command.cancel_confirmed(ctx.command, first, 100)
    refute File.exists?("/proc/#{group}")

    {:ok, after_retry} = read(ctx.command, request, job)
    assert after_retry.cleanup_status == :confirmed
    assert after_retry.cleanup_error == before_retry.cleanup_error
    assert after_retry.status == before_retry.status
    assert after_retry.exit_status == before_retry.exit_status
    assert after_retry.termination_status == before_retry.termination_status
    assert after_retry.output == before_retry.output
    assert Map.has_key?(:sys.get_state(ctx.server).completed, job.port)

    stale_error = {:error, Error.new(:resource_conflict, "stale cleanup failure")}
    send(ctx.server, {:cleanup_result, port, token, stale_error})
    send(ctx.server, {:cleanup_result, {:session, session_id}, token, stale_error})
    send(ctx.server, {first_ref, stale_error})
    send(ctx.server, {:cleanup_timeout, port, token, first_ref})
    send(ctx.server, {:cleanup_result, {:session, session_id}, retry_token, stale_error})
    assert :confirmed = session_status(ctx.server, first)
    assert :confirmed = owner_status(ctx.server, "same-owner")
    assert {:ok, ^after_retry} = read(ctx.command, request, job)

    sibling = identity("same-owner")
    sibling_workspace = workspace(ctx.workspace, "sibling")
    sibling_request = command_request(sibling_workspace, sibling)
    assert {:ok, sibling_job} = Command.start(ctx.command, sibling_request, deadline_limit: 5_000)
    sibling_group = :sys.get_state(ctx.server).active[sibling_job.port].process_group_id
    assert :ok = Command.cancel(ctx.command, sibling)

    assert_receive {:cleanup_attempt, sibling_worker, sibling_port, _sibling_token,
                    ^sibling_group, 0},
                   1_000

    assert sibling_port == sibling_job.port
    send(sibling_worker, :continue)
    eventually(fn -> session_status(ctx.server, sibling) == :uncertain end)
    assert :uncertain = owner_status(ctx.server, "same-owner")
    assert :confirmed = session_status(ctx.server, first)
  end

  test "an active registry entry can release after host reconciliation; failed entries stay failed",
       ctx do
    registry = start_supervised!(ResourceRegistry)
    owner = "registry-owner"
    session_holder = :atomics.new(1, [])

    cleanup_identity = fn ->
      %{owner_run_id: owner, incarnation: 1, session_id: :atomics.get(session_holder, 1)}
    end

    {:ok, session_id} =
      ResourceRegistry.register_session(registry, owner, %{job: nil},
        incarnation: 1,
        cleanup: fn -> Command.cancel_confirmed(ctx.command, cleanup_identity.(), 1_000) end,
        acknowledge: fn _ -> Command.acknowledge_release(ctx.command, cleanup_identity.()) end
      )

    :atomics.put(session_holder, 1, session_id)

    identity = %{identity(owner) | session_id: session_id}
    request = command_request(workspace(ctx.workspace, "registry"), identity)
    assert {:ok, job} = Command.start(ctx.command, request, deadline_limit: 5_000)
    assert :ok = ResourceRegistry.update_session(registry, session_id, owner, %{job: job}, 1)
    group = :sys.get_state(ctx.server).active[job.port].process_group_id

    assert :ok = Command.cancel(ctx.command, identity)
    assert_receive {:cleanup_attempt, worker, port, _token, ^group, 0}, 1_000
    assert port == job.port
    send(worker, :continue)
    eventually(fn -> session_status(ctx.server, identity) == :uncertain end)

    assert {:ok, %{status: :active}} =
             ResourceRegistry.session_cleanup_status(registry, session_id, owner, 1)

    retry = Task.async(fn -> Command.cancel_confirmed(ctx.command, identity, 2_000) end)

    assert_receive {:cleanup_attempt, retry_worker, {:session, ^session_id}, _retry_token, ^group,
                    1},
                   1_000

    send(retry_worker, :continue)
    assert :ok = Task.await(retry, 3_000)
    assert :confirmed = session_status(ctx.server, identity)
    assert {:ok, :ok} = ResourceRegistry.release_session(registry, session_id, owner, 1)

    eventually(fn ->
      match?(
        {:ok, %{status: :confirmed, acknowledgement: :ok}},
        ResourceRegistry.session_cleanup_status(registry, session_id, owner, 1)
      )
    end)

    {:ok, failed_id} =
      ResourceRegistry.register_session(registry, owner, %{job: :held},
        incarnation: 1,
        cleanup: fn -> {:error, :unresolved_host_obligation} end
      )

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release_session(registry, failed_id, owner, 1)

    assert {:ok, %{status: :failed}} =
             ResourceRegistry.session_cleanup_status(registry, failed_id, owner, 1)

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release_session(registry, failed_id, owner, 1)
  end

  defp identity(owner) do
    %{
      owner_run_id: owner,
      owner_pid: self(),
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic])
    }
  end

  defp workspace(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    path
  end

  defp command_request(workspace, identity) do
    Map.merge(identity, %{
      executable: "/bin/sh",
      arguments: ["-c", "printf 'output\\n'; read answer"],
      workspace: workspace,
      environment: %{}
    })
  end

  defp read(command, invocation, job), do: Command.read(command, invocation, job, cursor: 0)

  defp session_status(server, identity),
    do: GenServer.call(server, {:session_cleanup_status, identity})

  defp owner_status(server, owner), do: GenServer.call(server, {:owner_cleanup_status, owner})

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
