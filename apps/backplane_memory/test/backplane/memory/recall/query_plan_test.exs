defmodule Backplane.Memory.Recall.QueryPlanTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Recall.QueryPlan

  @partition %{
    host_id: "host-a",
    client_id: "client-a",
    scope: "team",
    namespace: "private"
  }

  test "normalizes Unicode and whitespace while preserving language and resolved filters" do
    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{
                 query: "  CAF\u00c9\t\u4f60\u597d\nwork  ",
                 project: " project-a ",
                 facets: [%{"dimension" => "kind", "value" => "decision"}],
                 temporal_hints: %{"after" => "2026-01-01T00:00:00Z"},
                 entity_hints: [" OTP ", "\u4f60\u597d"],
                 channel_weights: %{fts: 2.0, vector: 1, graph: 0.5},
                 token_budget: 2_048
               })
             )

    assert plan.normalized_query == "CAF\u00c9 \u4f60\u597d work"
    assert plan.project == "project-a"
    assert plan.entity_hints == ["OTP", "\u4f60\u597d"]
    assert plan.channel_weights == %{fts: 2.0, vector: 1.0, graph: 0.5}
    assert plan.token_budget == 2_048
    assert byte_size(plan.query_hash) == 32

    trace = QueryPlan.trace(plan)
    refute Map.has_key?(trace, "query")
    assert trace["normalized_query"] == "CAF\u00c9 \u4f60\u597d work"

    assert trace["partition"] == %{
             "host_id" => "host-a",
             "client_id" => "client-a",
             "scope" => "team",
             "namespace" => "private"
           }
  end

  test "requires an exact non-empty partition and rejects malformed or unknown input" do
    valid = Map.put(@partition, :query, "query")

    for key <- [:host_id, :client_id, :scope, :namespace] do
      assert {:error, {:invalid, ^key}} = QueryPlan.new(Map.delete(valid, key))
      assert {:error, {:invalid, ^key}} = QueryPlan.new(Map.put(valid, key, " \t"))
    end

    assert {:error, {:invalid, :query}} = QueryPlan.new(Map.put(valid, :query, <<255>>))

    assert {:error, {:unknown_keys, [:unexpected]}} =
             QueryPlan.new(Map.put(valid, :unexpected, 1))

    assert {:error, :invalid_query_plan} = QueryPlan.new([])
  end

  test "validates facets, hints, channel weights, and token budget with strict bounds" do
    valid = Map.put(@partition, :query, "query")

    assert {:error, {:invalid, :facets}} =
             QueryPlan.new(Map.put(valid, :facets, [%{"dimension" => "x"}]))

    assert {:error, {:invalid, :entity_hints}} =
             QueryPlan.new(Map.put(valid, :entity_hints, Enum.map(1..33, &"e#{&1}")))

    assert {:error, {:invalid, :temporal_hints}} =
             QueryPlan.new(Map.put(valid, :temporal_hints, %{"secret" => "x"}))

    assert {:error, {:invalid, :channel_weights}} =
             QueryPlan.new(Map.put(valid, :channel_weights, %{fts: -1}))

    assert {:error, {:invalid, :channel_weights}} =
             QueryPlan.new(Map.put(valid, :channel_weights, %{fts: "1"}))

    assert {:error, {:invalid, :channel_weights}} =
             QueryPlan.new(Map.put(valid, :channel_weights, %{unknown: 1}))

    assert {:error, {:invalid, :token_budget}} = QueryPlan.new(Map.put(valid, :token_budget, 0))

    assert {:error, {:invalid, :token_budget}} =
             QueryPlan.new(Map.put(valid, :token_budget, 100_001))
  end

  test "trace redacts secrets without changing the stable raw-query hash" do
    attrs = Map.merge(@partition, %{query: "token=super-secret find auth"})
    assert {:ok, first} = QueryPlan.new(attrs)
    assert {:ok, second} = QueryPlan.new(attrs)

    assert first.query_hash == second.query_hash
    assert QueryPlan.trace(first)["normalized_query"] =~ "[REDACTED]"
    refute QueryPlan.trace(first)["normalized_query"] =~ "super-secret"
  end
end
