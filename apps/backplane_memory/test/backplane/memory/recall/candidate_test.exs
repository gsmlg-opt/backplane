defmodule Backplane.Memory.Recall.CandidateTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Projections.ProjectedObservation
  alias Backplane.Memory.Recall.{Adapters, Candidate}
  alias Backplane.Memory.Summaries.Summary

  @partition %{
    host_id: "host-a",
    client_id: "client-a",
    scope: "team",
    namespace: "private"
  }

  test "builds the complete normalized contract with provenance and channel scores" do
    id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    assert {:ok, candidate} =
             Candidate.new(
               Map.merge(@partition, %{
                 id: id,
                 kind: :memory,
                 memory_type: :semantic,
                 content: "Use deterministic tests",
                 project: "backplane",
                 session_id: "session-a",
                 confidence: 0.9,
                 strength: 0.8,
                 evidence_count: 2,
                 source_ids: [source_id],
                 source_refs: [%{type: :event, id: source_id}],
                 channel_scores: %{fts: %{rank: 1, score: 0.7}},
                 lifecycle_state: :active,
                 token_estimate: 12
               })
             )

    assert %Candidate{
             id: ^id,
             kind: :memory,
             memory_type: :semantic,
             source_ids: [^source_id],
             source_refs: [%{type: :event, id: ^source_id}],
             lifecycle_state: :active,
             token_estimate: 12
           } = candidate
  end

  test "rejects invalid kinds, partitions, UUID provenance, scores, and bounds" do
    valid =
      Map.merge(@partition, %{
        id: Ecto.UUID.generate(),
        kind: :memory,
        memory_type: :semantic,
        content: "content",
        source_ids: [Ecto.UUID.generate()]
      })

    for {key, value} <- [
          {:kind, :unknown},
          {:memory_type, :unknown},
          {:host_id, ""},
          {:source_ids, ["not-a-uuid"]},
          {:confidence, 1.1},
          {:strength, -0.1},
          {:evidence_count, -1},
          {:token_estimate, 1_000_001},
          {:channel_scores, %{unknown: %{rank: 1, score: 1.0}}}
        ] do
      assert {:error, {:invalid, ^key}} = Candidate.new(Map.put(valid, key, value))
    end
  end

  test "typed retrieval rows preserve exact ownership and resolvable provenance" do
    memory_id = Ecto.UUID.generate()
    summary_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    source_event_id = Ecto.UUID.generate()

    assert {:ok,
            %Candidate{
              kind: :memory,
              id: ^memory_id,
              source_ids: [^memory_id],
              source_refs: [%{type: :memory, id: ^memory_id}]
            }} =
             Adapters.memory(%Adapters.MemoryRow{
               memory: %{
                 id: memory_id,
                 content: "fact",
                 memory_type: "semantic",
                 lifecycle_state: "active",
                 confidence: 1.0,
                 session_id: "s",
                 metadata: %{"project" => "p"}
               },
               partition: @partition,
               source_refs: [%Adapters.SourceRef{type: :memory, id: memory_id}]
             })

    summary = %Summary{
      id: summary_id,
      host_id: @partition.host_id,
      content: "summary",
      session_id: "s",
      project: "p"
    }

    assert {:ok,
            %Candidate{
              kind: :summary,
              source_ids: [^source_event_id],
              source_refs: [%{type: :event, id: ^source_event_id}]
            }} =
             Adapters.summary(%Adapters.SummaryRow{
               summary: summary,
               partition: @partition,
               source_refs: [%Adapters.SourceRef{type: :event, id: source_event_id}]
             })

    observation = %ProjectedObservation{
      event_id: event_id,
      host_id: @partition.host_id,
      client_id: @partition.client_id,
      scope: @partition.scope,
      namespace: @partition.namespace,
      content: "observation",
      session_id: "s",
      project: "p"
    }

    assert {:ok,
            %Candidate{
              kind: :observation,
              source_ids: [^event_id],
              source_refs: [%{type: :event, id: ^event_id}]
            }} =
             Adapters.observation(%Adapters.ObservationRow{
               observation: observation,
               partition: @partition,
               source_refs: [%Adapters.SourceRef{type: :event, id: event_id}]
             })
  end

  test "adapters reject bare artifacts, missing provenance, and mismatched typed sources" do
    id = Ecto.UUID.generate()

    assert {:error, :invalid_retrieval_row} =
             Adapters.summary(%Summary{id: id, content: "summary"})

    memory = %{id: id, content: "fact", memory_type: "semantic", lifecycle_state: "active"}

    assert {:error, :missing_provenance} =
             Adapters.memory(%Adapters.MemoryRow{
               memory: memory,
               partition: @partition,
               source_refs: []
             })

    assert {:error, :invalid_provenance} =
             Adapters.memory(%Adapters.MemoryRow{
               memory: memory,
               partition: @partition,
               source_refs: [%Adapters.SourceRef{type: :event, id: id}]
             })

    assert {:error, :partition_mismatch} =
             Adapters.summary(%Adapters.SummaryRow{
               summary: %Summary{id: id, host_id: "other", content: "summary"},
               partition: @partition,
               source_refs: [%Adapters.SourceRef{type: :event, id: Ecto.UUID.generate()}]
             })
  end

  test "typed provenance is closed and must exactly cover public source IDs" do
    source_id = Ecto.UUID.generate()

    attrs =
      Map.merge(@partition, %{
        id: Ecto.UUID.generate(),
        kind: :memory,
        memory_type: :semantic,
        content: "content",
        source_ids: [source_id]
      })

    assert {:error, {:invalid, :source_refs}} =
             Candidate.new(Map.put(attrs, :source_refs, [%{type: :unknown, id: source_id}]))

    assert {:error, {:invalid, :source_refs}} =
             Candidate.new(
               Map.put(attrs, :source_refs, [%{type: :event, id: Ecto.UUID.generate()}])
             )
  end

  test "lesson and crystal adapters are safe empty channels before M16 schemas exist" do
    assert {:ok, []} = Adapters.lessons(@partition)
    assert {:ok, []} = Adapters.crystals(@partition)
  end
end
