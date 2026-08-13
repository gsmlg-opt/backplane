defmodule Backplane.Memory.Recall.PipelineTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Recall.{Candidate, Pipeline, QueryPlan, Run, Store}
  alias Backplane.Memory.Memories

  @partition %{
    host_id: "pipeline-host",
    client_id: "pipeline-client",
    scope: "team",
    namespace: "private"
  }

  setup do
    previous = Application.get_env(:backplane_memory, :recall_task_supervisor)
    supervisor = start_supervised!({Task.Supervisor, name: unique_supervisor()})
    Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :recall_task_supervisor, previous),
        else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
    end)

    :ok
  end

  test "FTS-only recall returns normalized provenance-bearing results within budget" do
    candidate = candidate(content: "bounded result", tokens: 5)

    assert {:ok, result} =
             Pipeline.run(
               Map.merge(@partition, %{
                 query: "  bounded   query ",
                 token_budget: 5,
                 facets: [%{"dimension" => "language", "value" => "elixir"}]
               }),
               trace?: false,
               retriever_opts: [
                 channel_fns: %{
                   fts: fn %QueryPlan{
                             normalized_query: "bounded query",
                             facets: [%{"dimension" => "language", "value" => "elixir"}]
                           },
                           _ ->
                     {:ok, [{candidate, 0.9}]}
                   end,
                   vector: fn _, _ -> {:unavailable, :no_embedder} end,
                   graph: fn _, _ -> {:unavailable, :no_graph} end
                 }
               ],
               reranker_opts: [enabled: true, model: nil]
             )

    assert %{status: :ok, recall_run_id: nil, used_tokens: 5, token_budget: 5} = result

    assert [selected] = result.results
    assert selected.kind == :memory
    assert selected.memory_type == :semantic
    assert selected.content == "bounded result"
    assert selected.final_score > 0
    assert selected.score_breakdown.rrf > 0
    assert selected.source_ids == candidate.source_ids
    assert selected.confidence == 1.0
    assert selected.lifecycle_state == :active
    assert selected.token_estimate == 5
    assert result.channels.fts.status == :ok
    assert result.channels.vector.status == :unavailable
  end

  test "reranker failure is an exact fallback and telemetry contains no content" do
    candidate = candidate(content: "token=super-private", tokens: 3)
    handler = "pipeline-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:backplane, :memory, :recall, :stage],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{results: [result], recall_run_id: run_id}} =
             Pipeline.run(Map.merge(@partition, %{query: "token=super-private"}),
               trace?: true,
               request_id: "fallback-#{System.unique_integer([:positive])}",
               correlation_id: "fallback",
               retriever_opts: [
                 channel_fns: %{
                   fts: fn _, _ -> {:ok, [{candidate, 0.9}]} end,
                   vector: fn _, _ -> {:unavailable, :down} end,
                   graph: fn _, _ -> {:unavailable, :down} end
                 }
               ],
               reranker_opts: [
                 enabled: true,
                 model: "safe-model",
                 provider: fn _, _ -> {:error, "token=super-private"} end
               ]
             )

    assert result.id == candidate.id

    assert %Run{
             reranker_provider: "injected",
             reranker_model: "safe-model",
             reranker_status: "provider_error",
             reranker_error_class: "provider_error",
             reranker_duration_ms: duration
           } = repo().get!(Run, run_id)

    assert is_integer(duration) and duration >= 0
    events = collect_telemetry([])

    assert Enum.any?(events, fn {_m, metadata} ->
             metadata.stage == :reranker and metadata.status == :provider_error and
               metadata.error_class == "provider_error" and
               metadata.reranker_provider == "injected"
           end)

    assert Enum.any?(events, fn {_m, metadata} ->
             metadata.stage == :retrieval and
               metadata.channel_error_classes.vector == "unavailable" and
               metadata.channel_error_classes.graph == "unavailable"
           end)

    refute inspect(events) =~ "super-private"
  end

  test "enabled tracing persists completed candidates and stable trusted IDs" do
    candidate = candidate(tokens: 2)
    request_id = "pipeline-request-#{System.unique_integer([:positive])}"
    correlation_id = "pipeline-correlation"

    opts = [
      trace?: true,
      request_id: request_id,
      correlation_id: correlation_id,
      query_embedding_model: " embed-model ",
      retriever_opts: [
        channel_fns: %{
          fts: fn _, _ -> {:ok, [{candidate, 1.0}]} end,
          vector: fn _, _ -> {:unavailable, :down} end,
          graph: fn _, _ -> {:unavailable, :down} end
        }
      ],
      reranker_opts: [enabled: false, model: " rerank-model "]
    ]

    assert {:ok, %{recall_run_id: run_id}} =
             Pipeline.run(Map.merge(@partition, %{query: "trace query"}), opts)

    assert {:ok,
            %Run{
              status: "complete",
              request_id: ^request_id,
              correlation_id: ^correlation_id,
              query_embedding_model: "embed-model",
              reranker_model: "rerank-model"
            },
            [stored]} =
             Store.get(run_id, @partition)

    assert stored.selected
    assert stored.source_ids == candidate.source_ids
    assert stored.source_refs["refs"] != []
    assert stored.pre_reranker_rank == 1
    assert stored.post_reranker_rank == 1

    assert %Run{
             reranker_provider: "none",
             reranker_status: "disabled",
             reranker_error_class: "disabled",
             reranker_duration_ms: duration
           } = repo().get!(Run, run_id)

    assert is_integer(duration) and duration >= 0

    flunk_retriever_opts =
      Keyword.put(opts[:retriever_opts], :channel_fns, %{
        fts: fn _, _ -> flunk("complete replay must not retrieve") end,
        vector: fn _, _ -> flunk("complete replay must not retrieve") end,
        graph: fn _, _ -> flunk("complete replay must not retrieve") end
      })

    flunk_opts = Keyword.put(opts, :retriever_opts, flunk_retriever_opts)

    assert {:error, :recall_already_complete} =
             Pipeline.run(Map.merge(@partition, %{query: "trace query"}), flunk_opts)
  end

  test "successful reranking persists provider metadata and candidate movement" do
    first = candidate(content: "first")
    second = candidate(content: "second")

    assert {:ok, %{recall_run_id: run_id}} =
             Pipeline.run(Map.merge(@partition, %{query: "movement"}),
               trace?: true,
               request_id: "movement-#{System.unique_integer([:positive])}",
               correlation_id: "movement",
               retriever_opts: [
                 channel_fns: %{
                   fts: fn _, _ -> {:ok, [{first, 1.0}, {second, 0.5}]} end,
                   vector: fn _, _ -> {:unavailable, :down} end,
                   graph: fn _, _ -> {:unavailable, :down} end
                 }
               ],
               reranker_opts: [
                 enabled: true,
                 model: "rerank-v1",
                 provider: fn _, _ ->
                   {:ok, [%{token: 1, score: 0.9}, %{token: 0, score: 0.4}]}
                 end
               ]
             )

    assert {:ok,
            %Run{
              reranker_provider: "injected",
              reranker_model: "rerank-v1",
              reranker_status: "ok",
              reranker_error_class: "none",
              reranker_duration_ms: duration
            }, stored} = Store.get(run_id, @partition)

    assert is_integer(duration) and duration >= 0
    movement = Map.new(stored, &{&1.candidate_id, {&1.pre_reranker_rank, &1.post_reranker_rank}})
    assert movement[first.id] == {1, 2}
    assert movement[second.id] == {2, 1}
  end

  test "a terminal trace finalization error safely marks an existing trace failed" do
    candidate = candidate()
    request_id = "failed-request-#{System.unique_integer([:positive])}"

    assert {:error, :trace_finalize_failed} =
             Pipeline.run(Map.merge(@partition, %{query: "failure"}),
               trace?: true,
               request_id: request_id,
               correlation_id: "failed-correlation",
               retriever_opts: [
                 channel_fns: %{
                   fts: fn _, _ -> {:ok, [{candidate, :invalid_score}]} end,
                   vector: fn _, _ -> {:unavailable, :down} end,
                   graph: fn _, _ -> {:unavailable, :down} end
                 }
               ],
               reranker_opts: [enabled: false]
             )

    assert %Run{status: "failed", failure_class: "trace_finalize_failed"} =
             repo().get_by!(Run, request_id: request_id)

    assert {:error, :recall_already_failed} =
             Pipeline.run(Map.merge(@partition, %{query: "failure"}),
               trace?: true,
               request_id: request_id,
               correlation_id: "failed-correlation",
               retriever_opts: [
                 channel_fns: %{
                   fts: fn _, _ -> flunk("failed replay must not retrieve") end,
                   vector: fn _, _ -> flunk("failed replay must not retrieve") end,
                   graph: fn _, _ -> flunk("failed replay must not retrieve") end
                 }
               ]
             )
  end

  test "invalid options and partitions fail closed before providers run" do
    provider = fn _, _ -> flunk("provider must not run") end
    assert {:error, {:invalid, :host_id}} = Pipeline.run(%{query: "q"})

    assert {:error, :invalid_options} =
             Pipeline.run(Map.merge(@partition, %{query: "q"}), unknown: true)

    assert {:error, :invalid_options} =
             Pipeline.run(Map.merge(@partition, %{query: "q"}), [1])

    assert {:error, {:invalid, :facets}} =
             Pipeline.run(Map.merge(@partition, %{query: "q", facets: [%{"dimension" => "x"}]}),
               retriever_opts: [channel_fns: %{fts: provider}]
             )

    invalid_nested = [
      {:retriever_opts, [1]},
      {:retriever_opts, [timeout_ms: 1, timeout_ms: 2]},
      {:retriever_opts, [timeout_mz: 1]},
      {:retriever_opts, [timeout_ms: 0]},
      {:post_fusion_opts, [1]},
      {:post_fusion_opts, [limit: 1, limit: 2]},
      {:post_fusion_opts, [limt: 1]},
      {:post_fusion_opts, [limit: 0]},
      {:reranker_opts, [1]},
      {:reranker_opts, [top_k: 1, top_k: 2]},
      {:reranker_opts, [top_ke: 1]},
      {:reranker_opts, [top_k: 0]},
      {:packer_opts, [1]},
      {:packer_opts, [max_per_session: 1, max_per_session: 2]},
      {:packer_opts, [max_per_sesion: 1]},
      {:packer_opts, [max_per_session: 0]}
    ]

    for {stage, stage_opts} <- invalid_nested do
      assert {:error, :invalid_options} =
               Pipeline.run(
                 Map.merge(@partition, %{query: "q"}),
                 [
                   retriever_opts: [channel_fns: %{fts: provider}],
                   trace?: false
                 ]
                 |> Keyword.put(stage, stage_opts)
               )
    end
  end

  test "real database FTS remains available with embedding and LLM unavailable" do
    assert {:ok, memory} =
             Memories.remember("real pipeline fts outage",
               agent_id: @partition.client_id,
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               idempotency_key: "real-pipeline-source",
               idempotency_scope: "pipeline-test"
             )

    assert {:ok, %{results: [%{id: id, source_ids: source_ids}], channels: channels}} =
             Pipeline.run(Map.merge(@partition, %{query: "real pipeline fts outage"}),
               trace?: false,
               retriever_opts: [embed_fn: fn _, _, _ -> {:error, :embedder_down} end],
               reranker_opts: [enabled: true, model: nil]
             )

    assert id == memory.id
    assert source_ids != []
    assert channels.fts.status == :ok
    assert channels.vector.status == :error
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, _event, measurements, metadata} ->
        collect_telemetry([{measurements, metadata} | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp candidate(opts \\ []) do
    id = Ecto.UUID.generate()

    {:ok, candidate} =
      Candidate.new(
        Map.merge(@partition, %{
          id: id,
          kind: :memory,
          memory_type: :semantic,
          content: Keyword.get(opts, :content, "result"),
          source_ids: [id],
          source_refs: [%{type: :memory, id: id}],
          token_estimate: Keyword.get(opts, :tokens, 1)
        })
      )

    candidate
  end

  defp unique_supervisor,
    do: String.to_atom("pipeline_test_supervisor_#{System.unique_integer([:positive])}")
end
