defmodule BackplaneMemory.Workers.AccessWritebackWorkerTest do
  use BackplaneMemory.DataCase, async: false

  import Ecto.Query

  alias BackplaneMemory.Memory
  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Workers.AccessWritebackWorker

  describe "perform/1" do
    test "increments access_count and sets accessed_at for given memory IDs" do
      {:ok, m1} = Memory.remember("fact one", agent_id: "a", host_id: "h")
      {:ok, m2} = Memory.remember("fact two", agent_id: "a", host_id: "h")

      before_count =
        from(m in MemorySchema, where: m.id == ^m1.id, select: m.access_count)
        |> repo().one()

      assert before_count == 0

      job = %Oban.Job{args: %{"memory_ids" => [m1.id, m2.id]}}
      assert :ok = AccessWritebackWorker.perform(job)

      after_row =
        from(m in MemorySchema,
          where: m.id == ^m1.id,
          select: %{access_count: m.access_count, accessed_at: m.accessed_at}
        )
        |> repo().one()

      assert after_row.access_count == 1
      assert after_row.accessed_at != nil
    end

    test "increments access_count each time it is called" do
      {:ok, mem} = Memory.remember("repeated access", agent_id: "a", host_id: "h")
      job = %Oban.Job{args: %{"memory_ids" => [mem.id]}}

      :ok = AccessWritebackWorker.perform(job)
      :ok = AccessWritebackWorker.perform(job)

      count =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.access_count)
        |> repo().one()

      assert count == 2
    end
  end

  describe "enqueue/1" do
    test "returns {:ok, :noop} for an empty list" do
      assert {:ok, :noop} = AccessWritebackWorker.enqueue([])
    end
  end
end
