defmodule BackplaneMemory.Memories.SearchTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Memories.Search
  alias BackplaneMemory.Memory

  @dim 2560

  defp vec(positions) do
    for i <- 0..(@dim - 1), do: Map.get(positions, i, 0.0)
  end

  defp embed_const(vector), do: fn _texts, _mode, _opts -> {:ok, [vector]} end
  defp embed_error(reason), do: fn _texts, _mode, _opts -> {:error, reason} end

  defp insert_with_embedding(content, vector, opts) do
    {:ok, mem} = Memory.remember(content, opts)
    mem |> MemorySchema.embed_changeset(vector) |> repo().update!()
    mem
  end

  describe "recall/2" do
    test "returns rows ordered by cosine distance ascending" do
      base = [agent_id: "a", host_id: "h"]
      near = insert_with_embedding("near", vec(%{0 => 1.0}), base)
      mid = insert_with_embedding("mid", vec(%{0 => 1.0, 1 => 1.0}), base)
      far = insert_with_embedding("far", vec(%{1 => 1.0}), base)

      query_vec = vec(%{0 => 1.0})

      assert {:ok, [r1, r2, r3]} =
               Search.recall("anything", limit: 10, embed_fn: embed_const(query_vec))

      assert [r1.id, r2.id, r3.id] == [near.id, mid.id, far.id]
      assert r1.distance <= r2.distance
      assert r2.distance <= r3.distance
    end

    test "excludes rows without embeddings" do
      base = [agent_id: "a", host_id: "h"]
      {:ok, _unembedded} = Memory.remember("no embed", base)
      with_embed = insert_with_embedding("yes embed", vec(%{0 => 1.0}), base)

      assert {:ok, [%{id: id}]} =
               Search.recall("q", embed_fn: embed_const(vec(%{0 => 1.0})))

      assert id == with_embed.id
    end

    test "excludes soft-deleted rows" do
      base = [agent_id: "a", host_id: "h"]
      alive = insert_with_embedding("alive", vec(%{0 => 1.0}), base)
      dead = insert_with_embedding("dead", vec(%{0 => 1.0}), base)
      :ok = Memory.forget(dead.id)

      assert {:ok, [%{id: id}]} =
               Search.recall("q", embed_fn: embed_const(vec(%{0 => 1.0})))

      assert id == alive.id
    end

    test "filters by scope" do
      a_opts = [agent_id: "a", host_id: "h", scope: "alpha"]
      b_opts = [agent_id: "a", host_id: "h", scope: "beta"]
      alpha = insert_with_embedding("alpha row", vec(%{0 => 1.0}), a_opts)
      _beta = insert_with_embedding("beta row", vec(%{0 => 1.0}), b_opts)

      assert {:ok, [%{id: id}]} =
               Search.recall("q",
                 scope: "alpha",
                 embed_fn: embed_const(vec(%{0 => 1.0}))
               )

      assert id == alpha.id
    end

    test "filters by agent_id and host_id" do
      mem_a =
        insert_with_embedding("row a", vec(%{0 => 1.0}),
          agent_id: "agent-1",
          host_id: "host-1"
        )

      _mem_b =
        insert_with_embedding("row b", vec(%{0 => 1.0}),
          agent_id: "agent-2",
          host_id: "host-1"
        )

      _mem_c =
        insert_with_embedding("row c", vec(%{0 => 1.0}),
          agent_id: "agent-1",
          host_id: "host-2"
        )

      assert {:ok, [%{id: id}]} =
               Search.recall("q",
                 agent_id: "agent-1",
                 host_id: "host-1",
                 embed_fn: embed_const(vec(%{0 => 1.0}))
               )

      assert id == mem_a.id
    end

    test "respects :limit" do
      base = [agent_id: "a", host_id: "h"]
      for i <- 0..4, do: insert_with_embedding("row #{i}", vec(%{0 => 1.0}), base)

      assert {:ok, results} =
               Search.recall("q", limit: 2, embed_fn: embed_const(vec(%{0 => 1.0})))

      assert length(results) == 2
    end

    test "returns {:error, reason} when embed function fails" do
      assert {:error, "vLLM down"} =
               Search.recall("q", embed_fn: embed_error("vLLM down"))
    end

    test "result map does not contain :embedding" do
      _ =
        insert_with_embedding("x", vec(%{0 => 1.0}),
          agent_id: "a",
          host_id: "h"
        )

      assert {:ok, [result]} =
               Search.recall("q", embed_fn: embed_const(vec(%{0 => 1.0})))

      refute Map.has_key?(result, :embedding)
    end
  end

  describe "hybrid_recall/2" do
    test "falls back to full-text search when vector search is unavailable" do
      {:ok, mem} =
        Memory.remember("fallback keyword memory",
          agent_id: "agent-text",
          host_id: "host-text",
          scope: "text-scope"
        )

      assert {:ok, [%{id: id}]} =
               Search.hybrid_recall("fallback keyword",
                 scope: "text-scope",
                 embed_fn: embed_error(:embedding_model_not_configured)
               )

      assert id == mem.id
    end

    test "uses vector results only when vector search is available" do
      vector_mem =
        insert_with_embedding(
          "vector memory",
          vec(%{0 => 1.0}),
          agent_id: "agent-vector",
          host_id: "host-vector",
          scope: "vector-scope"
        )

      {:ok, _text_only_mem} =
        Memory.remember("text-only keyword",
          agent_id: "agent-vector",
          host_id: "host-vector",
          scope: "vector-scope"
        )

      assert {:ok, [%{id: id}]} =
               Search.hybrid_recall("text-only keyword",
                 scope: "vector-scope",
                 embed_fn: embed_const(vec(%{0 => 1.0}))
               )

      assert id == vector_mem.id
    end
  end
end
