defmodule Backplane.Memory.Recall.PostFusionTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Recall.{Candidate, PostFusion}

  @now ~U[2026-08-12 00:00:00Z]

  test "uses exact bounded lifecycle math and preserves trace scores" do
    item =
      fused(candidate(confidence: 0.8, strength: 0.6, evidence_count: 5, application_count: 4))

    assert {:ok, [trace]} = PostFusion.apply([item], now: @now, max_per_session: 3)
    assert trace.selected
    assert trace.rejection_reason == nil
    assert_in_delta trace.scores.lifecycle, 0.97812, 1.0e-8
    assert_in_delta trace.scores.final, item.scores.rrf * 0.97812, 1.0e-10
  end

  test "recency cannot erase a new relevant item and older equal evidence ranks lower" do
    new = fused(candidate(id: uuid(1), inserted_at: @now))
    old = fused(candidate(id: uuid(2), inserted_at: DateTime.add(@now, -730, :day)))

    assert {:ok, [new_trace, old_trace]} =
             PostFusion.apply([old, new], now: @now, max_per_session: 3)

    assert new_trace.candidate.id == new.candidate.id
    assert new_trace.scores.lifecycle > old_trace.scores.lifecycle
    assert old_trace.scores.lifecycle >= 0.9
  end

  test "disputed is penalized while superseded archived and tombstoned are rejected" do
    items = [
      fused(candidate(id: uuid(1), lifecycle_state: :active)),
      fused(candidate(id: uuid(2), lifecycle_state: :disputed)),
      fused(candidate(id: uuid(3), lifecycle_state: :superseded)),
      fused(candidate(id: uuid(4), lifecycle_state: :archived)),
      fused(candidate(id: uuid(5), lifecycle_state: :tombstoned))
    ]

    assert {:ok, traces} = PostFusion.apply(items, now: @now, max_per_session: 3, limit: 4)
    by_id = Map.new(traces, &{&1.candidate.id, &1})
    assert by_id[uuid(1)].selected
    assert by_id[uuid(2)].selected
    assert by_id[uuid(2)].scores.lifecycle < by_id[uuid(1)].scores.lifecycle
    assert by_id[uuid(2)].candidate.lifecycle_state == :disputed
    assert by_id[uuid(3)].rejection_reason == "superseded"
    assert by_id[uuid(4)].rejection_reason == "archived"
    assert by_id[uuid(5)].rejection_reason == "lifecycle"
  end

  test "application utility reinforces but access count never does" do
    base = fused(candidate(id: uuid(1), application_count: 0))
    accessed = fused(candidate(id: uuid(2), application_count: 0))
    applied = fused(candidate(id: uuid(3), application_count: 10))

    assert {:error, {:unknown_keys, [:access_count]}} =
             Candidate.new(Map.from_struct(base.candidate) |> Map.put(:access_count, 10_000))

    assert {:ok, traces} = PostFusion.apply([base, accessed, applied], now: @now)
    by_id = Map.new(traces, &{&1.candidate.id, &1.scores.lifecycle})
    assert by_id[uuid(1)] == by_id[uuid(2)]
    assert by_id[uuid(3)] > by_id[uuid(1)]
  end

  test "session cap rejects overflow but fills unused capacity from other sessions" do
    items =
      for index <- 1..5 do
        session = if index <= 4, do: "one", else: "two"
        fused(candidate(id: uuid(index), session_id: session), 1.0 - index / 100)
      end

    assert {:ok, traces} = PostFusion.apply(items, now: @now, max_per_session: 3, limit: 4)
    selected = Enum.filter(traces, & &1.selected)
    assert Enum.count(selected, &(&1.candidate.session_id == "one")) == 3
    assert Enum.count(selected, &(&1.candidate.session_id == "two")) == 1
    assert Enum.find(traces, &(&1.candidate.id == uuid(4))).rejection_reason == "diversity"
  end

  test "deferred same-session candidates fill otherwise unused capacity" do
    items =
      for index <- 1..4,
          do: fused(candidate(id: uuid(index), session_id: "one"), 1.0 - index / 100)

    assert {:ok, traces} = PostFusion.apply(items, now: @now, max_per_session: 3, limit: 4)
    assert Enum.all?(traces, & &1.selected)
  end

  test "nil sessions are independent and lifecycle candidate is positively penalized" do
    nil_session = [
      fused(candidate(id: uuid(1), session_id: nil)),
      fused(candidate(id: uuid(2), session_id: nil)),
      fused(candidate(id: uuid(3), lifecycle_state: :candidate))
    ]

    assert {:ok, traces} = PostFusion.apply(nil_session, now: @now, max_per_session: 1, limit: 3)
    assert Enum.all?(traces, & &1.selected)
    candidate_trace = Enum.find(traces, &(&1.candidate.id == uuid(3)))
    assert candidate_trace.scores.lifecycle > 0.0
    assert candidate_trace.scores.lifecycle < 1.0
  end

  test "expired candidate is rejected and malformed fusion input fails closed" do
    expired = fused(candidate(id: uuid(1), expires_at: DateTime.add(@now, -1, :second)))
    assert {:ok, [trace]} = PostFusion.apply([expired], now: @now)
    assert trace.rejection_reason == "lifecycle"

    assert {:error, :invalid_fused_item} =
             PostFusion.apply([%{candidate: expired.candidate}], now: @now)

    assert {:error, :invalid_fused_item} =
             PostFusion.apply([put_in(expired, [:scores, :rrf], :nan)], now: @now)

    attrs = Map.from_struct(expired.candidate) |> Map.put(:expires_at, "invalid")
    assert {:error, {:invalid, :expires_at}} = Candidate.new(attrs)
  end

  test "exact final ties preserve fusion best-rank then kind and UUID order" do
    first = %{fused(candidate(id: uuid(2))) | ranks: %{fts: 2}}
    second = %{fused(candidate(id: uuid(1))) | ranks: %{fts: 1}}
    assert {:ok, traces} = PostFusion.apply([first, second], now: @now)
    assert Enum.map(traces, & &1.candidate.id) == [uuid(1), uuid(2)]
  end

  test "options are a closed unique keyword contract" do
    for opts <- [[1], [limit: 1, limit: 2], [max_per_sesion: 1]] do
      assert {:error, :invalid_options} = PostFusion.apply([], opts)
    end
  end

  test "comparable alternative kinds interrupt a kind monopoly deterministically" do
    items = [
      fused(candidate(id: uuid(1), kind: :memory), 1.00),
      fused(candidate(id: uuid(2), kind: :memory), 0.99),
      fused(candidate(id: uuid(3), kind: :summary, memory_type: :episodic), 0.98),
      fused(candidate(id: uuid(4), kind: :memory), 0.50)
    ]

    assert {:ok, first} = PostFusion.apply(items, now: @now, limit: 3)
    assert {:ok, second} = PostFusion.apply(Enum.reverse(items), now: @now, limit: 3)
    assert Enum.map(first, & &1.candidate.id) == Enum.map(second, & &1.candidate.id)
    assert Enum.take(Enum.map(first, & &1.candidate.kind), 3) == [:memory, :summary, :memory]
  end

  test "candidate partition and provenance remain unchanged" do
    candidate = candidate(source_ids: [uuid(20)], host_id: "h", client_id: "c")
    assert {:ok, [trace]} = PostFusion.apply([fused(candidate)], now: @now)
    assert trace.candidate == candidate
  end

  defp fused(candidate, rrf \\ 0.02),
    do: %{candidate: candidate, ranks: %{fts: 1}, scores: %{fts: 1.0, rrf: rrf}}

  defp candidate(opts) do
    attrs = %{
      id: Keyword.get(opts, :id, uuid(100)),
      kind: Keyword.get(opts, :kind, :memory),
      memory_type: Keyword.get(opts, :memory_type, :semantic),
      content: "candidate",
      host_id: Keyword.get(opts, :host_id, "host"),
      client_id: Keyword.get(opts, :client_id, "client"),
      scope: "team",
      namespace: "private",
      session_id: Keyword.get(opts, :session_id, "session"),
      confidence: Keyword.get(opts, :confidence, 1.0),
      strength: Keyword.get(opts, :strength, 1.0),
      evidence_count: Keyword.get(opts, :evidence_count, 1),
      source_ids: Keyword.get(opts, :source_ids, [uuid(200)]),
      lifecycle_state: Keyword.get(opts, :lifecycle_state, :active),
      channel_scores: %{},
      token_estimate: 3,
      inserted_at: Keyword.get(opts, :inserted_at, @now),
      expires_at: Keyword.get(opts, :expires_at),
      application_count: Keyword.get(opts, :application_count, 0)
    }

    {:ok, candidate} = Candidate.new(attrs)
    candidate
  end

  defp uuid(integer),
    do: "00000000-0000-4000-8000-#{integer |> Integer.to_string() |> String.pad_leading(12, "0")}"
end
