defmodule BackplaneMemory.Memories.SearchExpansionTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Memories.Search
  alias BackplaneMemory.Memory

  @dim 2560

  defp vec(positions) do
    for i <- 0..(@dim - 1), do: Map.get(positions, i, 0.0)
  end

  defp embed_const(vector), do: fn _texts, _mode, _opts -> {:ok, [vector]} end

  defp insert_with_embedding(content, vector, opts) do
    {:ok, mem} = Memory.remember(content, opts)
    mem |> MemorySchema.embed_changeset(vector) |> repo().update!()
    mem
  end

  defmodule MockLLMExpand do
    def expand_query(query), do: {:ok, [query, query <> " alternative"]}
    def rerank(_query, candidates), do: {:ok, Enum.reverse(candidates)}
  end

  defmodule MockLLMNoLLM do
    def expand_query(_query), do: {:skip, :no_llm}
    def rerank(_query, _candidates), do: {:skip, :no_llm}
  end

  setup do
    prev_reranker = Backplane.Settings.get("memory.reranker_enabled")
    prev_expansion = Backplane.Settings.get("memory.query_expansion_enabled")

    on_exit(fn ->
      # Restore ETS-backed settings to their original values
      Backplane.Settings.set("memory.reranker_enabled", prev_reranker)
      Backplane.Settings.set("memory.query_expansion_enabled", prev_expansion)
    end)

    :ok
  end

  describe "query expansion" do
    test "expansion skips when LLM returns {:skip, :no_llm}" do
      # MockLLMNoLLM.expand_query returns {:skip, :no_llm}
      # hybrid_recall should still work with just the original query
      base = [agent_id: "a", host_id: "h"]
      _m = insert_with_embedding("elixir programming", vec(%{0 => 1.0}), base)

      {:ok, results} =
        Search.hybrid_recall("elixir",
          limit: 10,
          embed_fn: embed_const(vec(%{0 => 1.0})),
          llm_module: MockLLMNoLLM
        )

      # Should return results using only the original query (no crash, no duplication)
      assert is_list(results)
    end

    test "expansion deduplicates results when expanded queries match same memory" do
      # MockLLMExpand returns [original, "original alternative"]
      # Both queries may hit the same memory; it should appear only once
      base = [agent_id: "a", host_id: "h"]
      mem = insert_with_embedding("elixir programming language", vec(%{0 => 1.0}), base)

      {:ok, results} =
        Search.hybrid_recall("elixir",
          limit: 10,
          embed_fn: embed_const(vec(%{0 => 1.0})),
          llm_module: MockLLMExpand
        )

      ids = Enum.map(results, & &1.id)
      # The memory should appear exactly once despite being matched by both queries
      assert Enum.count(ids, &(&1 == mem.id)) == 1
    end
  end

  describe "reranker" do
    test "reranker skips when memory.reranker_enabled is not 'true'" do
      # Default: reranker_enabled not set → candidates returned as-is (not reversed)
      base = [agent_id: "b", host_id: "h"]
      m1 = insert_with_embedding("first memory", vec(%{0 => 1.0}), base)
      m2 = insert_with_embedding("second memory", vec(%{0 => 0.9, 1 => 0.1}), base)

      {:ok, results} =
        Search.hybrid_recall("first",
          limit: 10,
          embed_fn: embed_const(vec(%{0 => 1.0})),
          llm_module: MockLLMExpand
        )

      ids = Enum.map(results, & &1.id)
      # Both memories should appear; reranker reversal is NOT applied so m1 leads on vector score
      assert m1.id in ids
      assert m2.id in ids
      # m1 should rank before m2 (closer in vector space to query)
      assert Enum.find_index(ids, &(&1 == m1.id)) < Enum.find_index(ids, &(&1 == m2.id))
    end

    test "reranker reorders when memory.reranker_enabled is 'true'" do
      # MockLLMExpand.rerank/2 reverses the list
      # With reranker enabled, results should come back in reversed order
      base = [agent_id: "c", host_id: "h"]
      m1 = insert_with_embedding("aardvark biology", vec(%{0 => 1.0}), base)
      m2 = insert_with_embedding("zebra biology", vec(%{0 => 0.5, 1 => 0.5}), base)

      # Disable expansion so we have predictable fused order before reranking
      {:ok, pre_results} =
        Search.hybrid_recall("biology",
          limit: 10,
          embed_fn: embed_const(vec(%{0 => 1.0})),
          llm_module: MockLLMNoLLM
        )

      pre_ids = Enum.map(pre_results, & &1.id)
      assert m1.id in pre_ids
      assert m2.id in pre_ids

      # Now enable reranker (MockLLMExpand reverses the order)
      Backplane.Settings.set("memory.reranker_enabled", "true")

      {:ok, reranked_results} =
        Search.hybrid_recall("biology",
          limit: 10,
          embed_fn: embed_const(vec(%{0 => 1.0})),
          llm_module: MockLLMExpand
        )

      reranked_ids = Enum.map(reranked_results, & &1.id)
      # Reversal from MockLLMExpand means order should be opposite of pre_ids
      assert reranked_ids == Enum.reverse(pre_ids)
    end
  end
end
