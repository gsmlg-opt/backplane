defmodule Backplane.Memory.Workers.EmbedWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Workers.EmbedWorker
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Projections.State
  alias Backplane.Memory.Embedding.{CircuitBreaker, Client}

  @model "fixture/openai/text-embedding-3-large"

  setup do
    original = Application.fetch_env(:backplane_memory, :embed_model)
    Application.put_env(:backplane_memory, :embed_model, @model)
    CircuitBreaker.reset()

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:backplane_memory, :embed_model, value)
        :error -> Application.delete_env(:backplane_memory, :embed_model)
      end

      CircuitBreaker.reset()
    end)
  end

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

      assert :ok = EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, mock_embed)

      embedding_after =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> repo().one()

      assert embedding_after != nil

      assert %State{status: "complete", subject_id: memory_id} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      assert memory_id == mem.id
      assert repo().get!(MemorySchema, mem.id).embedding_model == @model
    end

    test "does not request embeddings or change processing state for a tombstoned memory" do
      partition = canonical_partition("h")
      {:ok, mem} = Memories.remember("Governed source", canonical_memory_opts("h", agent_id: "a"))
      assert :ok = Memories.tombstone(mem.id, partition)
      tombstone = repo().get!(MemorySchema, mem.id)
      state = repo().get_by(State, projector: "embedding", subject_id: mem.id)

      assert :ok =
               EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, fn _, _, _ ->
                 flunk("tombstoned memory reached the provider")
               end)

      assert repo().get!(MemorySchema, mem.id) == tombstone
      assert repo().get_by(State, projector: "embedding", subject_id: mem.id) == state
    end

    test "a completion after forget cannot persist a vector or model provenance" do
      partition = canonical_partition("h")

      {:ok, mem} =
        Memories.remember("In-flight source", canonical_memory_opts("h", agent_id: "a"))

      embed = fn _, _, _ ->
        assert :ok = Memories.tombstone(mem.id, partition)
        Process.put(:embedding_tombstone, repo().get!(MemorySchema, mem.id))

        Process.put(
          :embedding_tombstone_state,
          repo().get_by(State, projector: "embedding", subject_id: mem.id)
        )

        {:ok, [List.duplicate(0.003, 2560)]}
      end

      assert :ok = EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, embed)
      assert repo().get!(MemorySchema, mem.id) == Process.get(:embedding_tombstone)

      assert repo().get_by(State, projector: "embedding", subject_id: mem.id) ==
               Process.get(:embedding_tombstone_state)
    end

    test "pins the request model and persisted provenance across a setting change" do
      {:ok, mem} =
        Memories.remember("Pinned embedding source", canonical_memory_opts("h", agent_id: "a"))

      vector = List.duplicate(0.003, 2560)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["model"] == @model
        Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => vector}]})
      end)

      embed = fn texts, mode, opts ->
        Application.put_env(:backplane_memory, :embed_model, "replacement/model")
        Client.embed(texts, mode, Keyword.put(opts, :req_options, plug: {Req.Test, __MODULE__}))
      end

      assert :ok = EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, embed)
      stored = repo().get!(MemorySchema, mem.id)
      assert stored.embedding_model == @model
      assert stored.embedding == Pgvector.HalfVector.new(vector)
    end

    test "does not fabricate provenance or request an embedding without a selected model" do
      Application.delete_env(:backplane_memory, :embed_model)

      {:ok, mem} =
        Memories.remember("Unconfigured source", canonical_memory_opts("h", agent_id: "a"))

      assert {:error, :embedding_model_not_configured} =
               EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, fn _, _, _ ->
                 flunk("unconfigured request reached the embedding client")
               end)

      stored = repo().get!(MemorySchema, mem.id)
      assert stored.embedding == nil
      assert stored.embedding_model == mem.embedding_model
    end

    test "vector-only changesets preserve existing model provenance" do
      memory = %MemorySchema{embedding_model: "historical/model"}
      changeset = MemorySchema.embed_changeset(memory, List.duplicate(0.001, 2560))
      assert Ecto.Changeset.get_field(changeset, :embedding_model) == "historical/model"
    end

    test "returns {:error, reason} when embed client fails so Styx retries" do
      {:ok, mem} =
        Memories.remember("Madrid is in Spain.", canonical_memory_opts("h", agent_id: "a"))

      failing_embed = fn _texts, _mode, _opts -> {:error, "vLLM unavailable"} end

      assert {:error, "vLLM unavailable"} =
               EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, failing_embed)

      embedding =
        from(m in MemorySchema, where: m.id == ^mem.id, select: m.embedding)
        |> repo().one()

      assert is_nil(embedding)
      assert repo().get!(MemorySchema, mem.id).embedding_model == mem.embedding_model

      assert %State{status: "failed", last_error: "vLLM unavailable"} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)

      assert {:error, "vLLM unavailable"} =
               EmbedWorker.perform_with_client(
                 %Styx.Job{args: %{"id" => mem.id}, attempt: 5, max_attempts: 5},
                 failing_embed
               )

      assert %State{status: "dead_letter", last_error: "vLLM unavailable"} =
               repo().get_by!(State, projector: "embedding", subject_id: mem.id)
    end

    test "returns :ok for a non-existent memory id (graceful skip)" do
      job = %Styx.Job{args: %{"id" => Ecto.UUID.generate()}}
      mock_embed = fn _texts, _mode, _opts -> {:ok, [[]]} end
      assert :ok = EmbedWorker.perform_with_client(job, mock_embed)
    end

    test "records dead-letter before reraising an exception on the final attempt" do
      {:ok, mem} =
        Memories.remember("Exception source", canonical_memory_opts("h", agent_id: "a"))

      raising_embed = fn _texts, _mode, _opts -> raise "embedding exploded" end

      assert_raise RuntimeError, "embedding exploded", fn ->
        EmbedWorker.perform_with_client(
          %Styx.Job{args: %{"id" => mem.id}, attempt: 5, max_attempts: 5},
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
          EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, fn _texts,
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
      Application.put_env(:backplane_memory, :embed_model, "replacement/model")

      assert :ok =
               EmbedWorker.perform_with_client(%Styx.Job{args: %{"id" => mem.id}}, fn _texts,
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
      assert repo().get!(MemorySchema, mem.id).embedding_model == "replacement/model"
    end
  end
end
