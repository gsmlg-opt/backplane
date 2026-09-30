defmodule Backplane.AgentRuntime.CodexCommandReceiptsTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  if match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") and
       is_binary(System.find_executable("coreutils")) do
    :ok
  else
    @moduletag skip: "command receipt regressions require Linux and coreutils"
  end

  setup %{tmp_dir: workspace} do
    server =
      start_supervised!(
        {LocalCommand,
         name: nil, receipt_capacity: 2, session_capacity: 4, completion_retention: 50}
      )

    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    %{
      server: server,
      registry: registry,
      command: command,
      context: %{
        workspace: workspace,
        command: command,
        session_registry: registry,
        caller: %{run_id: "receipt-run"},
        incarnation: 7,
        owner_pid: self()
      }
    }
  end

  test "acknowledged successful commands retain only a bounded recent receipt cache", ctx do
    for _ <- 1..8 do
      assert {:ok, %{exit_code: 0}} =
               Codex.call(ctx.context, "exec_command", %{
                 "cmd" => "printf complete",
                 "login" => false,
                 "yield_time_ms" => 1_000
               })

      eventually(fn -> map_size(:sys.get_state(ctx.server).completed) == 0 end)
    end

    state = :sys.get_state(ctx.server)
    assert Enum.count(state.released_sessions) <= 2
    assert map_size(state.completed) <= 1
    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "receipt-run")
  end

  test "unconsumed confirmed evidence survives unrelated receipt eviction", ctx do
    held = identity()
    assert :ok = Command.reserve(ctx.command, held)
    assert :ok = Command.cancel_confirmed(ctx.command, held, 500)

    for _ <- 1..8 do
      assert {:ok, %{exit_code: 0}} =
               Codex.call(ctx.context, "exec_command", %{
                 "cmd" => "true",
                 "login" => false,
                 "yield_time_ms" => 1_000
               })

      eventually(fn -> map_size(:sys.get_state(ctx.server).completed) == 0 end)
    end

    assert :ok = Command.cancel_confirmed(ctx.command, held, 500)
    assert :ok = Command.acknowledge_release(ctx.command, held)
    assert :ok = Command.cancel_confirmed(ctx.command, held, 500)

    for _ <- 1..3 do
      later = identity()
      assert :ok = Command.reserve(ctx.command, later)
      assert :ok = Command.cancel_confirmed(ctx.command, later, 500)
      assert :ok = Command.acknowledge_release(ctx.command, later)
    end

    assert {:error, %Error{class: :unknown_outcome, details: %{receipt: :expired}}} =
             Command.cancel_confirmed(ctx.command, held, 500)

    assert {:error, %Error{class: :cancelled}} = Command.reserve(ctx.command, held)
    assert map_size(:sys.get_state(ctx.server).session_obligations) == 0
    assert :queue.len(:sys.get_state(ctx.server).released_order) <= 2
  end

  test "reserved identities fence cancellation before binding and enforce owner and incarnation",
       ctx do
    held = identity()
    assert :ok = Command.reserve(ctx.command, held)

    assert {:error, %Error{class: :forbidden}} =
             Command.cancel_confirmed(ctx.command, %{held | owner_run_id: "other"}, 100)

    assert {:error, %Error{class: :resource_conflict}} =
             Command.cancel_confirmed(ctx.command, %{held | incarnation: 8}, 100)

    assert :ok = Command.cancel_confirmed(ctx.command, held, 100)

    request =
      Map.merge(held, %{
        executable: "/bin/sh",
        arguments: ["-c", "printf late > late"],
        workspace: ctx.tmp_dir,
        environment: %{}
      })

    assert {:error, %Error{class: :cancelled}} = Command.start(ctx.command, request)
    refute File.exists?(Path.join(ctx.tmp_dir, "late"))
    assert :ok = Command.acknowledge_release(ctx.command, held)
  end

  test "unresolved reservations apply admission backpressure instead of evicting evidence", ctx do
    held =
      for _ <- 1..4 do
        id = identity()
        assert :ok = Command.reserve(ctx.command, id)
        id
      end

    assert {:error, %Error{class: :overloaded}} = Command.reserve(ctx.command, identity())
    assert map_size(:sys.get_state(ctx.server).session_obligations) == 4

    for id <- held do
      assert :ok = Command.cancel_confirmed(ctx.command, id, 100)
      assert :ok = Command.acknowledge_release(ctx.command, id)
    end
  end

  test "missing identity stays unknown and a cancellation fence prevents later launch", ctx do
    unknown = identity()

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(ctx.command, unknown, 100)

    assert {:error, %Error{class: :cancelled}} = Command.reserve(ctx.command, unknown)

    assert :sys.get_state(ctx.server).session_obligations[unknown.session_id].status ==
             :fenced_unknown
  end

  test "repeated known non-start refusals do not accumulate permanent receipts", ctx do
    assert {:ok, %{session_id: running}} =
             Codex.call(ctx.context, "exec_command", %{
               "cmd" => "read answer; printf done",
               "login" => false,
               "yield_time_ms" => 0
             })

    for _ <- 1..8 do
      assert {:error, %Error{class: :resource_conflict}} =
               Codex.call(ctx.context, "exec_command", %{
                 "cmd" => "printf refused",
                 "login" => false,
                 "yield_time_ms" => 0
               })

      eventually(fn -> map_size(:sys.get_state(ctx.server).session_obligations) == 1 end)
    end

    state = :sys.get_state(ctx.server)
    assert map_size(state.released_sessions) <= 2
    assert state.cleanup_evidence == %{}

    assert {:ok, [%{id: ^running, status: :active}]} =
             ResourceRegistry.owner_status(ctx.registry, "receipt-run")

    assert {:ok, %{output: "done"}} =
             Codex.call(ctx.context, "write_stdin", %{
               "session_id" => running,
               "chars" => "continue\n",
               "yield_time_ms" => 1_000
             })

    eventually(fn -> map_size(:sys.get_state(ctx.server).session_obligations) == 0 end)
  end

  test "failed native cleanup survives output eviction and successful receipt churn", ctx do
    failure_workspace = Path.join(ctx.tmp_dir, "uncertain")
    File.mkdir_p!(failure_workspace)
    failed_server = ctx.server
    failed_command = ctx.command

    :sys.replace_state(failed_server, fn state ->
      original = state.cleanup_reconciler

      reconciler = fn owner, port, token, group ->
        group_record = Map.get(:sys.get_state(owner).owned_groups, port)

        if is_nil(group_record) or group_record.workspace == failure_workspace do
          {:error, Error.new(:resource_conflict, "injected unresolved native cleanup")}
        else
          original.(owner, port, token, group)
        end
      end

      %{state | cleanup_reconciler: reconciler}
    end)

    held = identity()

    request =
      Map.merge(held, %{
        workspace: failure_workspace,
        executable: "/bin/sh",
        arguments: ["-c", "true"],
        environment: %{}
      })

    {:ok, _job} = Command.start(failed_command, request)
    eventually(fn -> map_size(:sys.get_state(failed_server).cleanup_evidence) == 1 end)
    evidence = :sys.get_state(failed_server).cleanup_evidence[held.session_id]
    eventually(fn -> map_size(:sys.get_state(failed_server).completed) == 0 end)

    for _ <- 1..8 do
      assert {:ok, %{exit_code: 0}} =
               Codex.call(ctx.context, "exec_command", %{
                 "cmd" => "true",
                 "login" => false,
                 "yield_time_ms" => 1_000
               })

      eventually(fn -> map_size(:sys.get_state(ctx.server).completed) == 0 end)
    end

    assert :sys.get_state(failed_server).cleanup_evidence[held.session_id] == evidence
    assert :uncertain = GenServer.call(failed_server, {:session_cleanup_status, held.session_id})
    assert map_size(:sys.get_state(failed_server).session_obligations) == 1

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(failed_command, held, 500)
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 2_000)

  defp eventually(fun, deadline) do
    if fun.(),
      do: :ok,
      else:
        if(System.monotonic_time(:millisecond) >= deadline,
          do: flunk("condition did not settle"),
          else:
            (
              Process.sleep(5)
              eventually(fun, deadline)
            )
        )
  end

  defp identity,
    do: %{
      owner_run_id: "receipt-run",
      incarnation: 7,
      session_id: System.unique_integer([:positive, :monotonic])
    }
end
