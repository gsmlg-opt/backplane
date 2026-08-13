defmodule Backplane.Memory.Recall.SelectionTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.Recall.{Candidate, Packer, Reranker}

  setup do
    supervisor = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: supervisor})
    %{supervisor: supervisor}
  end

  test "disabled, unavailable, and empty rerank paths are exact and make no provider call", %{
    supervisor: supervisor
  } do
    traces = traces()
    provider = fn _, _ -> flunk("provider must not be called") end

    assert {:ok, ^traces, %{status: :disabled, model: nil}} =
             Reranker.apply(traces, "query",
               enabled: false,
               provider: provider
             )

    assert {:ok, ^traces, %{status: :unavailable, model: nil}} =
             Reranker.apply(traces, "query",
               enabled: true,
               provider: provider
             )

    assert {:ok, [], %{status: :empty, model: "m"}} =
             Reranker.apply([], "query",
               enabled: true,
               model: "m",
               provider: provider,
               task_supervisor: supervisor
             )
  end

  test "successful rerank uses opaque tokens, deterministic scores, and existing final slots", %{
    supervisor: supervisor
  } do
    [a, b, c] = traces()

    provider = fn _query, candidates ->
      assert Enum.map(candidates, & &1.token) == [0, 1]
      {:ok, [%{token: 0, score: 0.2}, %{token: 1, score: 0.9}]}
    end

    original = [a, b, c]

    assert {:ok, [rb, ra, ^c], %{status: :ok, model: "model"}} =
             Reranker.apply(original, "query",
               enabled: true,
               top_k: 2,
               provider: provider,
               model: "model",
               task_supervisor: supervisor
             )

    assert original == [a, b, c]
    assert rb.candidate == b.candidate and rb.scores.reranker == 0.9
    assert ra.candidate == a.candidate and ra.scores.reranker == 0.2
    assert Enum.map([rb, ra], & &1.scores.final) == [0.9, 0.8]
  end

  test "provider receives only bounded privacy-filtered descriptors", %{supervisor: supervisor} do
    [trace | _] = traces()

    candidate = %{
      trace.candidate
      | content: "password=super-secret " <> String.duplicate("x", 40_000)
    }

    trace = %{trace | candidate: candidate}
    test_pid = self()

    provider = fn query, items ->
      send(test_pid, {:payload, query, items})
      {:ok, [%{token: 0, score: 1.0}]}
    end

    assert {:ok, [_], %{status: :ok}} =
             Reranker.apply([trace], "Authorization: Bearer abc.def",
               enabled: true,
               model: "m",
               provider: provider,
               task_supervisor: supervisor
             )

    assert_receive {:payload, query, [%{token: 0, kind: "memory", content: content} = item]}
    assert Map.keys(item) |> Enum.sort() == [:content, :kind, :memory_type, :token]
    refute query =~ "abc.def"
    refute content =~ "super-secret"
    assert String.length(query) <= 2_000
    assert String.length(content) <= 2_000
    assert String.length(query) + String.length(content) <= 32_000
  end

  test "provider failure matrix preserves exact traces and privacy-safe status", %{
    supervisor: supervisor
  } do
    traces = traces()

    providers = [
      fn _, _ -> {:error, "secret"} end,
      fn _, _ -> exit(:boom) end,
      fn _, _ -> raise "private failure" end,
      fn _, _ -> throw("private failure") end,
      fn _, _ -> Process.exit(self(), :kill) end,
      fn _, _ -> Process.sleep(100) end,
      fn _, _ -> {:ok, :bad} end,
      fn _, _ -> {:ok, [%{token: 0, score: 1.0}, %{token: 0, score: 0.5}]} end,
      fn _, _ -> {:ok, [%{token: 99, score: 1.0}, %{token: 0, score: 0.5}]} end,
      fn _, _ -> {:ok, [%{token: 1, score: 1.0}]} end,
      fn _, _ -> {:ok, [%{token: 0, score: -0.1}, %{token: 1, score: 0.2}]} end,
      fn _, _ -> {:ok, [%{token: 0, score: 1.1}, %{token: 1, score: 0.2}]} end
    ]

    for provider <- providers do
      assert {:ok, ^traces, %{status: status, model: "m"}} =
               Reranker.apply(traces, "query",
                 enabled: true,
                 top_k: 2,
                 timeout_ms: 10,
                 provider: provider,
                 model: "m",
                 task_supervisor: supervisor
               )

      assert status in [:provider_error, :exit, :timeout, :malformed]
    end
  end

  test "timeout kills the provider task", %{supervisor: supervisor} do
    test_pid = self()

    provider = fn _, _ ->
      send(test_pid, {:provider_pid, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, _, %{status: :timeout}} =
             Reranker.apply(traces(), "query",
               enabled: true,
               model: "m",
               timeout_ms: 10,
               provider: provider,
               task_supervisor: supervisor
             )

    assert_receive {:provider_pid, pid}
    refute Process.alive?(pid)
  end

  test "reranker rejects malformed options and duplicate typed identities without raising", %{
    supervisor: supervisor
  } do
    [trace | _] = traces()

    for opts <- [
          [top_k: 0],
          [top_k: 501],
          [timeout_ms: 0],
          [timeout_ms: 60_001],
          [provider: :not_a_function],
          [task_supervisor: :missing_supervisor]
        ] do
      assert {:error, :invalid_options} =
               Reranker.apply(
                 [trace],
                 "q",
                 [enabled: true, model: "m"] ++
                   opts ++
                   [task_supervisor: supervisor]
               )
    end

    assert {:error, :invalid_traces} =
             Reranker.apply([trace, trace], "q",
               enabled: true,
               model: "m",
               task_supervisor: supervisor
             )
  end

  test "reranker and packer options are closed unique keyword contracts" do
    for opts <- [[1], [top_k: 1, top_k: 2], [top_ke: 1]] do
      assert {:error, :invalid_options} = Reranker.apply([], "q", opts)
    end

    for opts <- [[1], [max_per_session: 1, max_per_session: 2], [max_per_sesion: 1]] do
      assert {:error, :invalid_options} = Packer.pack([], 10, opts)
    end
  end

  test "packing never exceeds budget and prefers marginal relevance per token over rank" do
    [a, b, c] = traces([9, 5, 5], [0.9, 0.8, 0.8])
    assert {:ok, packed, %{used_tokens: 10, token_budget: 10}} = Packer.pack([a, b, c], 10)
    selected = Enum.filter(packed, & &1.selected)
    assert Enum.map(selected, & &1.candidate.id) == [b.candidate.id, c.candidate.id]
    assert Enum.all?(selected, &(&1.candidate.source_ids != []))

    assert Enum.find(packed, &(&1.candidate.id == a.candidate.id)).rejection_reason ==
             "token_budget"
  end

  test "packing handles zero cost, exact boundary, oversize, and prior rejection" do
    [zero, exact, oversize, prior] = traces([0, 10, 11, 1], [0.1, 0.8, 1.0, 0.7])
    prior = %{prior | selected: false, rejection_reason: "diversity"}

    assert {:ok, first, %{used_tokens: 10}} = Packer.pack([oversize, exact, zero, prior], 10)
    assert {:ok, second, _} = Packer.pack([prior, zero, exact, oversize], 10)

    project = fn rows -> Enum.map(rows, &{&1.candidate.id, &1.selected, &1.rejection_reason}) end
    assert project.(first) == project.(second)

    assert Enum.find(first, &(&1.candidate.id == prior.candidate.id)).rejection_reason ==
             "diversity"

    assert {:ok, zero_cost, %{used_tokens: 0}} = Packer.pack([zero], 1)
    assert hd(zero_cost).selected
  end

  test "packing reserves room for a comparable alternate kind and enforces session cap" do
    first = trace(1, 2, 0.9, kind: :memory, session_id: "same")
    monopolizer = trace(2, 2, 0.89, kind: :memory, session_id: "same")
    alternate = trace(3, 2, 0.82, kind: :lesson, session_id: "other")

    assert {:ok, packed, %{used_tokens: 4}} =
             Packer.pack([monopolizer, alternate, first], 4, max_per_session: 1)

    assert Enum.map(Enum.filter(packed, & &1.selected), & &1.candidate.kind) == [:memory, :lesson]
    refute Enum.find(packed, &(&1.candidate.id == monopolizer.candidate.id)).selected
  end

  test "packing fills otherwise unused budget from deferred same-session candidates" do
    candidates = for index <- 1..4, do: trace(index, 2, 1.0 - index / 100, session_id: "same")

    assert {:ok, packed, %{used_tokens: 8}} =
             Packer.pack(candidates, 8, max_per_session: 3)

    assert Enum.count(packed, & &1.selected) == 4
  end

  test "typed identity allows the same UUID across different kinds", %{supervisor: supervisor} do
    id = uuid(1)
    memory = trace(1, 2, 0.9, id: id, kind: :memory)
    lesson = trace(2, 2, 0.8, id: id, kind: :lesson)
    provider = fn _, _ -> {:ok, [%{token: 0, score: 0.8}, %{token: 1, score: 0.7}]} end

    assert {:ok, reranked, %{status: :ok}} =
             Reranker.apply([memory, lesson], "q",
               enabled: true,
               model: "m",
               provider: provider,
               task_supervisor: supervisor
             )

    assert {:ok, packed, %{used_tokens: 4}} = Packer.pack(reranked, 4)
    assert Enum.map(Enum.filter(packed, & &1.selected), & &1.candidate.kind) == [:memory, :lesson]
  end

  test "packer validates identity, trace score, and token consistency" do
    [trace | _] = traces()

    assert {:error, :invalid_traces} = Packer.pack([trace, trace], 10)
    assert {:error, :invalid_traces} = Packer.pack([put_in(trace.scores.final, -0.1)], 10)
    assert {:error, :invalid_traces} = Packer.pack([%{trace | token_estimate: 99}], 10)
    assert {:error, :invalid_options} = Packer.pack([trace], 10, max_per_session: 0)
    assert {:error, :invalid_token_budget} = Packer.pack([trace], 100_001)
  end

  defp traces(tokens \\ [4, 4, 4], scores \\ [0.9, 0.8, 0.7]) do
    Enum.zip(tokens, scores)
    |> Enum.with_index(1)
    |> Enum.map(fn {{token, score}, index} -> trace(index, token, score) end)
  end

  defp trace(index, tokens, score, opts \\ []) do
    {:ok, candidate} =
      Candidate.new(%{
        id: Keyword.get(opts, :id, uuid(index)),
        kind: Keyword.get(opts, :kind, :memory),
        memory_type: :semantic,
        content: "c",
        host_id: "h",
        client_id: "c",
        scope: "s",
        namespace: "n",
        session_id: Keyword.get(opts, :session_id, "s#{index}"),
        source_ids: [uuid(index + 100)],
        token_estimate: tokens
      })

    %{
      candidate: candidate,
      selected: true,
      rejection_reason: nil,
      ranks: %{fts: index},
      scores: %{rrf: score, lifecycle: 1.0, final: score},
      token_estimate: tokens
    }
  end

  defp uuid(integer),
    do: "00000000-0000-4000-8000-#{integer |> Integer.to_string() |> String.pad_leading(12, "0")}"
end
