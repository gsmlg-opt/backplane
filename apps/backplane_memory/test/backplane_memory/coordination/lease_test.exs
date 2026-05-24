defmodule BackplaneMemory.Coordination.LeaseTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Coordination.Lease

  describe "acquire/3" do
    test "first caller acquires the lease successfully" do
      action_id = Ecto.UUID.generate()
      assert {:ok, lease_id} = Lease.acquire(action_id, "agent-1", 300)
      assert is_binary(lease_id)
    end

    test "second caller for same action gets an error with holder info" do
      action_id = Ecto.UUID.generate()
      {:ok, _} = Lease.acquire(action_id, "agent-1", 300)

      assert {:error, %{held_by: "agent-1", expires_at: expires_at}} =
               Lease.acquire(action_id, "agent-2", 300)

      assert %DateTime{} = expires_at
    end

    test "expired lease can be re-acquired" do
      action_id = Ecto.UUID.generate()
      # Acquire with TTL of -1 second (already expired)
      {:ok, _} = Lease.acquire(action_id, "agent-1", -1)

      # Next acquire should succeed since the expired lease is cleaned up
      assert {:ok, _lease_id} = Lease.acquire(action_id, "agent-2", 300)
    end

    test "same agent can acquire different action_ids independently" do
      action1 = Ecto.UUID.generate()
      action2 = Ecto.UUID.generate()

      assert {:ok, _} = Lease.acquire(action1, "agent-1", 300)
      assert {:ok, _} = Lease.acquire(action2, "agent-1", 300)
    end
  end
end
