defmodule Backplane.Memory.Recall.FusionTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Recall.{Candidate, Fusion}

  @partition %{
    memory_space_id: "00000000-0000-4000-8000-000000000099",
    host_id: "h",
    client_id: "c",
    scope: "s",
    namespace: "n"
  }

  test "weighted RRF is deterministic, deduplicates identities, and exposes reproducible ranks" do
    a = candidate("00000000-0000-4000-8000-000000000001", :memory)
    b = candidate("00000000-0000-4000-8000-000000000002", :summary)
    c = candidate("00000000-0000-4000-8000-000000000003", :observation)

    channels = %{
      fts: outcome(:ok, [{a, 0.9}, {b, 0.8}]),
      vector: outcome(:ok, [{b, 0.99}, {a, 0.7}]),
      graph: outcome(:ok, [{c, 1.0}])
    }

    assert {:ok, first} = Fusion.fuse(channels, %{fts: 1.0, vector: 2.0, graph: 1.0}, 60)
    assert {:ok, second} = Fusion.fuse(channels, %{fts: 1.0, vector: 2.0, graph: 1.0}, 60)
    assert first == second
    assert Enum.map(first, & &1.candidate.id) == [b.id, a.id, c.id]
    assert length(first) == 3
    assert hd(first).ranks == %{fts: 2, vector: 1}
    assert hd(first).scores.vector == 0.99
    assert_in_delta hd(first).scores.rrf, 0.25 / 62.0 + 0.5 / 61.0, 1.0e-12
  end

  test "available-channel weights renormalize and a single channel preserves stable channel order" do
    a = candidate("00000000-0000-4000-8000-000000000001", :memory)
    b = candidate("00000000-0000-4000-8000-000000000002", :memory)

    channels = %{
      fts: outcome(:ok, [{a, 1.0}, {b, 1.0}]),
      vector: outcome(:error, [], :provider_failed),
      graph: outcome(:unavailable, [])
    }

    assert {:ok, fused} = Fusion.fuse(channels, %{fts: 2.0, vector: 98.0, graph: 0.0}, 60)
    assert Enum.map(fused, & &1.candidate.id) == [a.id, b.id]
    assert_in_delta hd(fused).scores.rrf, 1.0 / 61.0, 1.0e-12
  end

  test "exact ties use kind order then UUID as the documented total-order tie breaker" do
    memory = candidate("00000000-0000-4000-8000-000000000002", :memory)
    summary = candidate("00000000-0000-4000-8000-000000000001", :summary)
    memory_low_id = candidate("00000000-0000-4000-8000-000000000001", :memory)

    channels = %{
      fts: outcome(:ok, [{memory, 1.0}, {summary, 1.0}, {memory_low_id, 1.0}]),
      vector: outcome(:ok, [{memory_low_id, 1.0}, {summary, 1.0}, {memory, 1.0}])
    }

    assert {:ok, fused} = Fusion.fuse(channels, %{fts: 1.0, vector: 1.0}, 60)

    assert Enum.map(fused, &{&1.candidate.kind, &1.candidate.id}) == [
             {:memory, memory_low_id.id},
             {:memory, memory.id},
             {:summary, summary.id}
           ]
  end

  test "duplicate identities within one channel and conflicting cross-channel candidates fail closed" do
    a = candidate("00000000-0000-4000-8000-000000000001", :memory)
    a_id = a.id

    assert {:error, {:duplicate_channel_candidate, :fts, {:memory, ^a_id}}} =
             Fusion.fuse(%{fts: outcome(:ok, [{a, 1.0}, {a, 0.9}])}, %{fts: 1.0}, 60)

    conflicting = %{a | content: "conflicting content"}

    assert {:error, {:conflicting_candidate, {:memory, ^a_id}}} =
             Fusion.fuse(
               %{fts: outcome(:ok, [{a, 1.0}]), vector: outcome(:ok, [{conflicting, 1.0}])},
               %{fts: 1.0, vector: 1.0},
               60
             )
  end

  test "revision-only drift selects the newest identical candidate regardless of channel order" do
    base = candidate("00000000-0000-4000-8000-000000000001", :memory)
    snapshots = Enum.map([100, 200, 300], &%{base | current_context: %{revision: &1}})
    newest = List.last(snapshots)

    for a <- snapshots, b <- snapshots -- [a], c <- snapshots -- [a, b] do
      channels = %{
        fts: outcome(:ok, [{a, 0.8}]),
        vector: outcome(:ok, [{b, 0.9}]),
        graph: outcome(:ok, [{c, 0.7}])
      }

      assert {:ok, [%{candidate: ^newest, ranks: ranks, scores: scores}]} =
               Fusion.fuse(channels, %{fts: 1.0, vector: 1.0, graph: 1.0}, 60)

      assert ranks == %{fts: 1, vector: 1, graph: 1}
      assert Map.take(scores, [:fts, :vector, :graph]) == %{fts: 0.8, vector: 0.9, graph: 0.7}
      assert_in_delta scores.rrf, 1.0 / 61.0, 1.0e-12
    end
  end

  test "revision drift cannot hide substantive candidate or support conflicts" do
    base = candidate("00000000-0000-4000-8000-000000000001", :memory)
    id = base.id

    before = %{
      base
      | current_context: %{
          revision: 100,
          trust: "candidate_inference",
          effective_support: true,
          support_complete: true,
          independent_support: false,
          source_refs: []
        }
    }

    newer = %{before | current_context: %{before.current_context | revision: 200}}

    conflicts = [
      %{newer | content: "different content"},
      %{newer | memory_space_id: Ecto.UUID.generate()},
      %{newer | host_id: "other host"},
      %{newer | client_id: "other client"},
      %{newer | scope: "other scope"},
      %{newer | namespace: "other namespace"},
      %{newer | source_ids: [Ecto.UUID.generate()]},
      %{newer | source_refs: [%{type: :event, id: Ecto.UUID.generate()}]},
      %{newer | evidence_count: 2},
      %{newer | confidence: 0.5},
      %{newer | lifecycle_state: :archived},
      put_in(newer.current_context.trust, "established_fact"),
      put_in(newer.current_context.effective_support, false),
      put_in(newer.current_context.support_complete, false),
      put_in(newer.current_context.independent_support, true),
      put_in(newer.current_context.source_refs, [%{event_id: Ecto.UUID.generate()}])
    ]

    for conflicting <- conflicts do
      assert {:error, {:conflicting_candidate, {:memory, ^id}}} =
               Fusion.fuse(
                 %{
                   fts: outcome(:ok, [{before, 1.0}]),
                   vector: outcome(:ok, [{conflicting, 1.0}])
                 },
                 %{fts: 1.0, vector: 1.0},
                 60
               )
    end
  end

  test "missing or non-integer revisions do not qualify for revision-only reconciliation" do
    base = candidate("00000000-0000-4000-8000-000000000001", :memory)
    id = base.id
    valid = %{base | current_context: %{revision: 100}}

    for context <- [%{}, %{revision: nil}, %{revision: "200"}, %{revision: 200.0}] do
      invalid = %{base | current_context: context}

      assert {:error, {:conflicting_candidate, {:memory, ^id}}} =
               Fusion.fuse(
                 %{fts: outcome(:ok, [{valid, 1.0}]), vector: outcome(:ok, [{invalid, 1.0}])},
                 %{fts: 1.0, vector: 1.0},
                 60
               )
    end
  end

  defp outcome(status, rows, error \\ nil),
    do: %{status: status, candidates: rows, error: error, duration_us: 1}

  defp candidate(id, kind) do
    type = if kind == :summary, do: :episodic, else: :semantic

    {:ok, candidate} =
      Candidate.new(
        Map.merge(@partition, %{
          id: id,
          kind: kind,
          memory_type: type,
          content: "#{kind}-#{id}",
          source_ids: [id]
        })
      )

    candidate
  end
end
