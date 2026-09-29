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
               cleanup: fn -> send(parent, :owner_cleaned) end
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
end
