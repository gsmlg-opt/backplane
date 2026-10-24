defmodule Backplane.Memory.Recall.RelevanceTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Recall.Relevance

  @calibration %{
    vector_model: "embedding-a",
    vector_min: 0.6,
    reranker_model: "provider/rerank-a",
    reranker_min: 0.7
  }

  test "raw semantic relevance can reject every unrelated candidate regardless of fused rank" do
    refute Relevance.accepted?(
             "query",
             "unrelated",
             %{vector: 0.05, final: 100},
             "embedding-a",
             nil,
             @calibration
           )

    assert Relevance.accepted?(
             "query",
             "related",
             %{vector: 0.8, final: 0.001},
             "embedding-a",
             nil,
             @calibration
           )
  end

  test "unknown or changed models require lexical evidence, while exact matches survive" do
    for model <- [nil, "embedding-b"] do
      refute Relevance.accepted?("query", "unrelated", %{vector: 0.99}, model, nil, @calibration)
      assert Relevance.accepted?("query", "Exact QUERY match", %{}, model, nil, @calibration)
    end

    assert Relevance.accepted?(
             "stemmed query",
             "lexically matched",
             %{fts: 0.01},
             nil,
             nil,
             @calibration
           )
  end

  test "retargetable aliases and unknown reranker identity cannot reuse a calibration" do
    alias_calibration = %{@calibration | reranker_model: "smart"}

    for changed_target_score <- [0.99, 0.95] do
      refute Relevance.accepted?(
               "query",
               "unrelated",
               %{reranker: changed_target_score},
               nil,
               "smart",
               alias_calibration
             )
    end

    refute Relevance.accepted?("query", "unrelated", %{reranker: 0.99}, nil, nil, @calibration)

    assert Relevance.accepted?(
             "query",
             "QUERY exact evidence",
             %{reranker: 0.99},
             nil,
             "smart",
             alias_calibration
           )
  end

  test "a calibrated reranker rejects weak semantic candidates instead of merely reordering" do
    refute Relevance.accepted?(
             "query",
             "unrelated",
             %{vector: 0.99, reranker: 0.1},
             "embedding-a",
             "provider/rerank-a",
             @calibration
           )

    assert Relevance.accepted?(
             "query",
             "related",
             %{reranker: 0.9},
             nil,
             "provider/rerank-a",
             @calibration
           )

    refute Relevance.accepted?(
             "query",
             "unrelated",
             %{reranker: 0.9},
             nil,
             "provider/rerank-b",
             @calibration
           )
  end
end
