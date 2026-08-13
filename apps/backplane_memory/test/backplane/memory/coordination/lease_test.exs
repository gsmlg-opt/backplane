defmodule Backplane.Memory.Coordination.LeaseTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Coordination.{Action, Lease}
  alias Backplane.Memory.Workers.LeaseCleanupWorker

  @partition %{
    host_id: "lease-host",
    client_id: "host:lease-host",
    scope: "lease-scope",
    namespace: "private"
  }

  describe "acquire/4" do
    test "first caller acquires the lease successfully" do
      action_id = action_id()
      assert {:ok, lease_id} = Lease.acquire(action_id, "agent-1", 300, @partition)
      assert is_binary(lease_id)

      assert [%{operation: "coordination.lease.acquire", target_ids: [^lease_id]}] =
               Audit.list(operation: "coordination.lease.acquire")
    end

    test "second caller for same action gets an error with holder info" do
      action_id = action_id()
      {:ok, _} = Lease.acquire(action_id, "agent-1", 300, @partition)

      assert {:error, %{held_by: "agent-1", expires_at: expires_at}} =
               Lease.acquire(action_id, "agent-2", 300, @partition)

      assert %DateTime{} = expires_at
    end

    test "expired lease can be re-acquired" do
      action_id = action_id()
      # Acquire with TTL of -1 second (already expired)
      {:ok, _} = Lease.acquire(action_id, "agent-1", -1, @partition)

      # Next acquire should succeed since the expired lease is cleaned up
      assert {:ok, _lease_id} = Lease.acquire(action_id, "agent-2", 300, @partition)

      assert [%{operation: "coordination.lease.cleanup", target_ids: [_expired_id]}] =
               Audit.list(operation: "coordination.lease.cleanup")
    end

    test "cleanup worker audits expired lease deletion" do
      action_id = action_id()
      {:ok, lease_id} = Lease.acquire(action_id, "agent-1", -1, @partition)

      assert {:ok, %{deleted: 1}} = LeaseCleanupWorker.perform(%Oban.Job{})

      assert [%{operation: "coordination.lease.cleanup", target_ids: [^lease_id]}] =
               Audit.list(operation: "coordination.lease.cleanup")
    end

    test "concurrent cleanup workers delete and audit an expired lease once" do
      action_id = action_id()
      {:ok, lease_id} = Lease.acquire(action_id, "agent-1", -1, @partition)

      results =
        1..2
        |> Task.async_stream(fn _ -> LeaseCleanupWorker.perform(%Oban.Job{}) end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.sort(results) == [{:ok, %{deleted: 0}}, {:ok, %{deleted: 1}}]

      assert [%{target_ids: [^lease_id], metadata: %{"count" => 1}}] =
               Audit.list(operation: "coordination.lease.cleanup")
    end

    test "same agent can acquire different action_ids independently" do
      action1 = action_id()
      action2 = action_id()

      assert {:ok, _} = Lease.acquire(action1, "agent-1", 300, @partition)
      assert {:ok, _} = Lease.acquire(action2, "agent-1", 300, @partition)
    end
  end

  defp action_id do
    {:ok, action} = Action.create(%{"title" => Ecto.UUID.generate()}, [], @partition)
    action.id
  end
end
