defmodule BackplaneMemory.Workers.EmbedWorkerTest do
  use BackplaneMemory.DataCase, async: false

  import Ecto.Query

  alias BackplaneMemory.Memory
  alias BackplaneMemory.Workers.EmbedWorker
  alias BackplaneMemory.Memories.Memory, as: MemorySchema

  describe "perform_with_client/2" do
    test "updates the embedding field of a memory row" do
      {:ok, mem} = Memory.remember("London is in the UK.", agent_id: "a", host_id: "h")

      embedding_before =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> Backplane.Repo.one()

      assert is_nil(embedding_before)

      vector = Enum.map(1..2560, fn _ -> 0.001 end)
      mock_embed = fn _texts, _mode, _opts -> {:ok, [vector]} end

      assert :ok = EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, mock_embed)

      embedding_after =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> Backplane.Repo.one()

      assert embedding_after != nil
    end

    test "returns {:error, reason} when embed client fails so Oban retries" do
      {:ok, mem} = Memory.remember("Madrid is in Spain.", agent_id: "a", host_id: "h")
      failing_embed = fn _texts, _mode, _opts -> {:error, "vLLM unavailable"} end

      assert {:error, "vLLM unavailable"} =
               EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, failing_embed)

      embedding =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> Backplane.Repo.one()

      assert is_nil(embedding)
    end

    test "returns :ok for a non-existent memory id (graceful skip)" do
      job = %Oban.Job{args: %{"id" => Ecto.UUID.generate()}}
      mock_embed = fn _texts, _mode, _opts -> {:ok, [[]]} end
      assert :ok = EmbedWorker.perform_with_client(job, mock_embed)
    end
  end
end
