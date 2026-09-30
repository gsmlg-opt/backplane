defmodule Backplane.AgentRuntime.CodexResourceRegistryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, Codex.ResourceRegistry}

  test "fences cross-owner and stale-incarnation handles and cleans on release" do
    {:ok, registry} = ResourceRegistry.start_link([])
    parent = self()

    cleanup = fn ->
      send(parent, :cleaned)
      :done
    end

    assert {:ok, handle} =
             ResourceRegistry.register(registry, "run_a", :command, %{pid: self()},
               incarnation: 2,
               cleanup: cleanup
             )

    assert {:ok, %{pid: _}} = ResourceRegistry.fetch(registry, handle, "run_a")
    assert {:error, %Error{class: :forbidden}} = ResourceRegistry.fetch(registry, handle, "run_b")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.fetch(registry, %{handle | incarnation: 1}, "run_a")

    assert {:ok, :done} = ResourceRegistry.release(registry, handle, "run_a")
    assert_receive :cleaned
    assert {:error, %Error{class: :not_found}} = ResourceRegistry.fetch(registry, handle, "run_a")
  end

  test "owner process death cleans owned resources" do
    {:ok, registry} = ResourceRegistry.start_link([])
    parent = self()

    owner = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, handle} =
             ResourceRegistry.register(registry, "run", :continuation, :live,
               owner_pid: owner,
               cleanup: fn ->
                 send(parent, :owner_cleaned)
                 :ok
               end
             )

    Process.exit(owner, :kill)
    assert_receive :owner_cleaned, 1_000
    assert {:error, %Error{class: :not_found}} = ResourceRegistry.fetch(registry, handle, "run")
  end

  test "numeric command sessions are owner-bound and stale after completion" do
    {:ok, registry} = ResourceRegistry.start_link([])

    assert {:ok, session_id} =
             ResourceRegistry.register_session(registry, "run-a", %{cursor: 0})

    assert is_integer(session_id)
    assert {:ok, %{cursor: 0}} = ResourceRegistry.fetch_session(registry, session_id, "run-a")

    assert {:error, %Error{class: :forbidden}} =
             ResourceRegistry.fetch_session(registry, session_id, "run-b")

    assert :ok =
             ResourceRegistry.update_session(registry, session_id, "run-a", %{cursor: 2})

    assert {:ok, %{cursor: 2}} = ResourceRegistry.fetch_session(registry, session_id, "run-a")
    assert :ok = ResourceRegistry.forget_session(registry, session_id, "run-a")

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch_session(registry, session_id, "run-a")
  end

  test "cleanup errors retain observable reconciliation evidence" do
    {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: 100)

    assert {:ok, handle} =
             ResourceRegistry.register(registry, "failed-run", :command, :live,
               cleanup: fn -> {:error, :cannot_stop} end
             )

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release(registry, handle, "failed-run")

    assert {:ok, %{status: :failed, reason: :cannot_stop}} =
             ResourceRegistry.cleanup_status(registry, handle, "failed-run")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.fetch(registry, handle, "failed-run")
  end

  test "a blocked cleanup times out without blocking another resource" do
    {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: 80)
    parent = self()

    assert {:ok, blocked} =
             ResourceRegistry.register(registry, "blocked", :command, :live,
               cleanup: fn ->
                 Process.flag(:trap_exit, true)
                 send(parent, :cleanup_started)
                 receive do: (:never -> :ok)
               end
             )

    caller = Task.async(fn -> ResourceRegistry.release(registry, blocked, "blocked") end)
    assert_receive :cleanup_started

    assert {:ok, fast} =
             ResourceRegistry.register(registry, "fast", :command, :live, cleanup: fn -> :ok end)

    assert {:ok, :ok} = ResourceRegistry.release(registry, fast, "fast")
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(caller)

    assert {:ok, %{status: :uncertain}} =
             ResourceRegistry.cleanup_status(registry, blocked, "blocked")
  end

  test "exceptions, exits, and asynchronous acknowledgement remain unresolved" do
    {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: 100)

    for {name, callback} <- [
          {"raise", fn -> raise "cleanup exploded" end},
          {"exit", fn -> exit(:cleanup_exited) end},
          {"pending", fn -> {:ok, :pending} end}
        ] do
      assert {:ok, handle} =
               ResourceRegistry.register(registry, name, :command, :live, cleanup: callback)

      assert {:error, %Error{class: :unknown_outcome}} =
               ResourceRegistry.release(registry, handle, name)

      assert {:ok, %{status: status}} = ResourceRegistry.cleanup_status(registry, handle, name)
      assert status in [:failed, :uncertain]

      assert {:error, %Error{class: :unknown_outcome}} =
               ResourceRegistry.release(registry, handle, name)
    end
  end

  test "concurrent release and owner death invoke cleanup once" do
    {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: 500)
    parent = self()
    owner = spawn(fn -> receive do: (:never -> :ok) end)

    assert {:ok, handle} =
             ResourceRegistry.register(registry, "race", :continuation, :live,
               owner_pid: owner,
               cleanup: fn ->
                 send(parent, {:cleanup_started, self()})
                 receive do: (:release -> :ok)
               end
             )

    release = Task.async(fn -> ResourceRegistry.release(registry, handle, "race") end)
    assert_receive {:cleanup_started, worker}
    Process.exit(owner, :kill)
    send(worker, :release)

    assert {:ok, :ok} = Task.await(release)
    refute_receive {:cleanup_started, _}, 50

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, "race")
  end

  test "a blocked receipt acknowledgement is bounded without blocking cleanup or cancellation" do
    registry = start_supervised!({ResourceRegistry, cleanup_timeout: 50})
    test = self()

    {:ok, id} =
      ResourceRegistry.register_session(registry, "ack-owner", %{job: nil},
        incarnation: 2,
        cleanup: fn -> :done end,
        acknowledge: fn _ ->
          send(test, {:acknowledging, self()})
          receive do: (:never -> :ok)
        end
      )

    assert {:ok, :done} = ResourceRegistry.release_session(registry, id, "ack-owner", 2)
    assert_receive {:acknowledging, worker}
    assert {:ok, []} = ResourceRegistry.cancel_owner(registry, "ack-owner")

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.session_cleanup_status(registry, id, "ack-owner", 2)

    Process.monitor(worker)
    assert_receive {:DOWN, _, :process, ^worker, :killed}, 500

    assert {:ok, %{status: :confirmed, acknowledgement: {:error, :acknowledgement_timeout}}} =
             ResourceRegistry.session_cleanup_status(registry, id, "ack-owner", 2)

    assert :sys.get_state(registry).tasks == %{}
  end

  test "late and duplicate cleanup replies do not reopen settled handles" do
    {:ok, registry} = ResourceRegistry.start_link(cleanup_timeout: 500)
    parent = self()

    assert {:ok, handle} =
             ResourceRegistry.register(registry, "late", :continuation, :live,
               cleanup: fn ->
                 send(parent, {:cleanup_started, self()})
                 receive do: (:release -> :ok)
               end
             )

    release = Task.async(fn -> ResourceRegistry.release(registry, handle, "late") end)
    assert_receive {:cleanup_started, worker}
    ref = :sys.get_state(registry).resources[handle.resource_id].task.ref
    send(worker, :release)
    assert {:ok, :ok} = Task.await(release)
    send(registry, {ref, {:error, :late_failure}})
    send(registry, {ref, {:ok, :late_success}})
    assert {:ok, :ok} = ResourceRegistry.release(registry, handle, "late")

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, "late")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.release(registry, %{handle | incarnation: 2}, "late")
  end
end
