defmodule Backplane.Memory.Workers.EmbedWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Workers.EmbedWorker
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Projections.State

  describe "perform_with_client/2" do
    test "updates the embedding field of a memory row" do
      {:ok, mem} =
        Memories.remember("London is in the UK.", canonical_memory_opts("h", agent_id: "a"))

      embedding_before =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> repo().one()

      assert is_nil(embedding_before)

      vector = Enum.map(1..2560, fn _ -> 0.001 end)
      mock_embed = fn _texts, _mode, _opts -> {:ok, [vector]} end

      assert :ok = EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, mock_embed)

      embedding_after =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> repo().one()

      assert embedding_after != nil

      assert %State{status: "complete", subject_id: memory_id} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      assert memory_id == mem.id
    end

    test "returns {:error, reason} when embed client fails so Oban retries" do
      {:ok, mem} =
        Memories.remember("Madrid is in Spain.", canonical_memory_opts("h", agent_id: "a"))

      failing_embed = fn _texts, _mode, _opts -> {:error, "vLLM unavailable"} end

      assert {:error, "vLLM unavailable"} =
               EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, failing_embed)

      embedding =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> repo().one()

      assert is_nil(embedding)

      assert %State{status: "failed", last_error: "vLLM unavailable"} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      assert {:error, "vLLM unavailable"} =
               EmbedWorker.perform_with_client(
                 %Oban.Job{args: %{"id" => mem.id}, attempt: 5, max_attempts: 5},
                 failing_embed
               )

      assert %State{status: "dead_letter", last_error: "vLLM unavailable"} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)
    end

    test "returns :ok for a non-existent memory id (graceful skip)" do
      job = %Oban.Job{args: %{"id" => Ecto.UUID.generate()}}
      mock_embed = fn _texts, _mode, _opts -> {:ok, [[]]} end
      assert :ok = EmbedWorker.perform_with_client(job, mock_embed)
    end

    test "records dead-letter before reraising an exception on the final attempt" do
      {:ok, mem} =
        Memories.remember("Exception source", canonical_memory_opts("h", agent_id: "a"))

      raising_embed = fn _texts, _mode, _opts -> raise "embedding exploded" end

      assert_raise RuntimeError, "embedding exploded", fn ->
        EmbedWorker.perform_with_client(
          %Oban.Job{args: %{"id" => mem.id}, attempt: 5, max_attempts: 5},
          raising_embed
        )
      end

      assert %State{status: "dead_letter", last_error: "embedding exploded"} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)
    end

    test "an old blocked embed completion cannot replace the current content revision state" do
      {:ok, mem} =
        Memories.remember("original embedding source", canonical_memory_opts("h", agent_id: "a"))

      parent = self()
      old_vector = Enum.map(1..2560, fn _ -> 0.001 end)

      old_task =
        Task.async(fn ->
          EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, fn _texts,
                                                                                 _mode,
                                                                                 _opts ->
            send(parent, :old_embed_blocked)

            receive do
              :release_old_embed -> {:ok, [old_vector]}
            end
          end)
        end)

      Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), old_task.pid)
      assert_receive :old_embed_blocked, 5_000

      new_content = "current embedding source"
      new_hash = :crypto.hash(:sha256, new_content)

      repo().update_all(from(memory in MemorySchema, where: memory.id == ^mem.id),
        set: [content: new_content, content_hash: new_hash]
      )

      new_vector = Enum.map(1..2560, fn _ -> 0.002 end)

      assert :ok =
               EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, fn _texts,
                                                                                      _mode,
                                                                                      _opts ->
                 {:ok, [new_vector]}
               end)

      new_revision = Base.encode16(new_hash, case: :lower)

      assert %State{status: "complete", input_revision: ^new_revision} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      send(old_task.pid, :release_old_embed)
      assert :ok = Task.await(old_task, 5_000)

      assert %State{status: "complete", input_revision: ^new_revision} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      embedding =
        repo().one(
          from(memory in MemorySchema, where: memory.id == ^mem.id, select: memory.embedding)
        )

      assert embedding == Pgvector.HalfVector.new(new_vector)
    end
  end
end
