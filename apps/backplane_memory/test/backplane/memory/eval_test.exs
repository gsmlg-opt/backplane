defmodule Backplane.Memory.EvalTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Eval

  test "loads the deterministic schema-v2 corpus with complete partitions and enough queries" do
    assert {:ok, fixture} = Eval.load_fixture()
    assert fixture["schema_version"] == 2
    assert is_binary(fixture["fixture_id"])
    assert length(fixture["queries"]) >= 20
    assert Enum.any?(fixture["memories"], & &1["distractor"])
    assert Enum.any?(fixture["memories"], & &1["derived"])

    assert Enum.all?(fixture["memories"], fn memory ->
             Enum.all?(
               ~w(fixture_memory_id host_id client_id scope namespace content),
               &is_binary(memory[&1])
             )
           end)
  end

  test "computes top-five quality metrics and fails a missed hit-rate gate" do
    cases = [
      %{relevant: ["a"], returned: ["a", "x"]},
      %{relevant: ["b", "c"], returned: ["x", "b", "c"]},
      %{relevant: ["d"], returned: ["x"]}
    ]

    metrics = Eval.quality_metrics(cases, 5)
    assert metrics.recall_any_at_5 == 2 / 3
    assert metrics.recall_all_at_5 == 2 / 3
    assert_in_delta metrics.mrr, (1.0 + 0.5) / 3, 1.0e-12
    assert metrics.ndcg_at_5 > 0.0
    refute Eval.thresholds_pass?(%{quality: metrics}, recall_any_at_5: 0.95)

    duplicate = Eval.quality_metrics([%{relevant: ["a"], returned: ["a", "a"]}], 5)
    assert duplicate.ndcg_at_5 == 1.0
  end

  test "the report requires measured latency, outage, and nonzero derived provenance gates" do
    report = %{
      quality: %{recall_any_at_5: 1.0},
      outage: %{availability: 1.0, samples: 20},
      provenance: %{coverage: 1.0, denominator: 2},
      latency: %{retrieval_fusion: %{p95_ms: 20, samples: 100}, e2e: %{p95_ms: 30, samples: 100}}
    }

    assert Eval.thresholds_pass?(report)
    refute Eval.thresholds_pass?(put_in(report, [:provenance, :denominator], 0))
    refute Eval.thresholds_pass?(put_in(report, [:latency, :e2e, :samples], 99))
    assert :ok = Eval.ensure_thresholds!(report)

    assert_raise RuntimeError, "M15 evaluation thresholds failed", fn ->
      Eval.ensure_thresholds!(put_in(report, [:quality, :recall_any_at_5], 0.0))
    end

    stronger_failure =
      report
      |> Map.put(:passed, false)
      |> Map.put(:thresholds, %{fts_outage_availability: false})
      |> put_in([:outage, :embedding_provider_calls], 0)
      |> put_in([:outage, :reranker_provider_calls], 0)
      |> put_in([:outage, :nonempty_fts_results], 0)

    assert Eval.thresholds_pass?(stronger_failure)

    assert_raise RuntimeError, "M15 evaluation thresholds failed", fn ->
      Eval.ensure_thresholds!(stronger_failure)
    end
  end

  test "ci scales latency gates while performance remains authoritative" do
    report = %{
      quality: %{recall_any_at_5: 1.0},
      outage: %{availability: 1.0, samples: 20},
      provenance: %{coverage: 1.0, denominator: 2},
      latency: %{
        retrieval_fusion: %{p95_ms: 1_000, samples: 100},
        e2e: %{p95_ms: 4_000, samples: 100}
      }
    }

    assert Eval.thresholds_pass?(report, profile: :ci)
    refute Eval.thresholds_pass?(report, profile: :performance)
  end

  test "LongMemEval export is explicitly retrieval-only and not directly comparable" do
    fixture = %{
      "fixture_id" => "fixture",
      "memories" => [%{"fixture_memory_id" => "m1", "content" => "needle memory"}],
      "queries" => [%{"query_id" => "q1", "query" => "needle", "relevant_ids" => ["m1"]}]
    }

    assert {jsonl, sidecar} = Eval.longmemeval_export(fixture, %{"q1" => ["m1"]})
    assert [line] = String.split(jsonl, "\n", trim: true)
    row = Jason.decode!(line)
    assert row["question_id"] == "q1"
    assert row["answer_session_ids"] == ["m1"]

    assert row["retrieval_results"]["ranked_items"] == [
             %{"corpus_id" => "m1", "text" => "needle memory", "timestamp" => nil}
           ]

    assert sidecar["evaluation_mode"] == "retrieval-only"
    assert sidecar["directly_comparable"] == false
  end

  test "LongMemEval export has all official retrieval cutoffs and evidence labels on every row" do
    assert {:ok, fixture} = Eval.load_fixture()
    returned = Map.new(fixture["queries"], &{&1["query_id"], &1["relevant_ids"]})
    {jsonl, _sidecar} = Eval.longmemeval_export(fixture, returned)
    rows = jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(rows) == 20

    for row <- rows do
      assert Enum.sort(Map.keys(row)) ==
               Enum.sort(
                 ~w(answer answer_session_ids haystack_dates haystack_session_ids haystack_sessions question question_date question_id question_type retrieval_results)
               )

      assert length(row["haystack_session_ids"]) == length(row["haystack_sessions"])
      assert Enum.any?(List.flatten(row["haystack_sessions"]), &(&1["has_answer"] == true))
      metrics = row["retrieval_results"]["metrics"]["session"]

      for k <- [1, 3, 5, 10, 30, 50], metric <- ["recall_any", "recall_all", "ndcg_any"] do
        assert is_number(metrics["#{metric}@#{k}"])
      end
    end
  end
end
