defmodule Backplane.Memory.Recall.PipelineTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Recall.{Pipeline, QueryPlan, Run, Store}
  alias Backplane.Memory.Memories

  @partition %{
    memory_space_id: "07099fca-7a4c-815b-6e6c-1eebe35dac04",
    host_id: "pipeline-host",
    client_id: "pipeline-client",
    scope: "team",
    namespace: "private"
  }

  setup do
    Backplane.Memory.IngestFixtures.ensure_memory_space!("pipeline-host")
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

  test "canonical recall keeps real governing source membership and revision, then excludes withdrawal without hiding operator history" do
    source = %{
      "integration" => "hermes",
      "installation_id" => Ecto.UUID.generate(),
      "profile_id" => "primary",
      "target" => "memory"
    }

    mutation = %{
      "protocol" => "memory_sources.v1",
      "source" => source,
      "entry_id" => Ecto.UUID.generate(),
      "event_id" => Ecto.UUID.generate(),
      "revision" => 7,
      "operation" => "upsert",
      "content" => "Hermes retrieval evidence",
      "type" => "semantic",
      "occurred_at" => "2026-10-24T01:00:00Z",
      "provenance" => %{"role" => "assistant"}
    }

    assert {:ok, %{canonical_id: id}} = Backplane.Memory.Sources.mutate(mutation, @partition)

    opts = [
      trace?: false,
      reranker_opts: [enabled: false],
      retriever_opts: [
        channel_fns: %{
          vector: fn _, _ -> {:unavailable, :down} end,
          graph: fn _, _ -> {:unavailable, :down} end
        }
      ]
    ]

    plan = Map.merge(@partition, %{query: "Hermes retrieval"})
    assert {:ok, %{results: [result]}} = Pipeline.run(plan, opts)
    assert result.id == id
    assert result.trust == "candidate_inference"
    assert result.support_complete

    assert [
             %{
               "source" => ^source,
               "entry_id" => entry,
               "source_revision" => 7,
               "event_id" => event,
               "active" => true
             }
           ] = result.source_refs

    assert entry == mutation["entry_id"]
    assert event == mutation["event_id"]
    assert result.evidence_refs != []

    assert [
             %{
               source_type: "request",
               source_id: request_id,
               evidence_kind: "derives",
               support_score: +0.0
             },
             %{source_type: "source_mutation", source_id: ^event}
           ] = Memories.list_evidence(id)

    request = repo().get!(Backplane.Memory.Memories.RememberRequest, request_id)
    assert request.origin == "external_source"
    refute request.independent_support

    refute Backplane.Memory.CurrentContext.metadata(
             repo().get!(Backplane.Memory.Memories.Memory, id)
           )["independent_support"]

    withdrawal =
      mutation
      |> Map.merge(%{
        "revision" => 8,
        "event_id" => Ecto.UUID.generate(),
        "operation" => "withdraw"
      })
      |> Map.delete("content")

    assert {:ok, _} = Backplane.Memory.Sources.mutate(withdrawal, @partition)
    assert {:ok, %{results: []}} = Pipeline.run(plan, opts)
    assert Enum.any?(Memories.list([], @partition), &(&1.id == id))
  end

  test "an actual embedded unrelated query can return zero with an inspectable raw-score rejection" do
    keys = ~w(memory.recall_relevance_vector_model memory.recall_relevance_vector_min)
    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      for {key, rows} <- snapshot do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, rows)
      end
    end)

    model = "provider/calibrated-embedding"
    :ets.insert(:backplane_settings, {"memory.recall_relevance_vector_model", model})
    :ets.insert(:backplane_settings, {"memory.recall_relevance_vector_min", 0.6})

    {:ok, memory} =
      Memories.remember(
        "Elixir concurrency preference",
        Map.to_list(@partition) ++ [agent_id: @partition.client_id]
      )

    repo().update!(
      Backplane.Memory.Memories.Memory.embed_changeset(
        memory,
        [1.0 | List.duplicate(0.0, 2559)],
        model
      )
    )

    assert {:ok, result} =
             Pipeline.run(Map.merge(@partition, %{query: "tropical marine biology"}),
               trace?: true,
               query_embedding_model: model,
               reranker_opts: [enabled: false],
               retriever_opts: [
                 embed_fn: fn _, _, _ -> {:ok, [[0.0, 1.0 | List.duplicate(0.0, 2558)]]} end
               ]
             )

    assert result.results == []
    assert result.channels.vector.count == 1
    assert {:ok, _, [stored]} = Store.get(result.recall_run_id, @partition)
    refute stored.selected
    assert stored.rejection_reason == "below_threshold"
    assert stored.vector_score == 0.0
  end

  test "canonical recall preserves current support, source revision and candidate trust without promoting request evidence" do
    {:ok, memory} =
      Memories.remember(
        "Elixir preference",
        Map.to_list(@partition) ++ [agent_id: @partition.client_id]
      )

    assert {:ok, result} =
             Pipeline.run(Map.merge(@partition, %{query: "Elixir"}),
               trace?: false,
               reranker_opts: [enabled: false],
               retriever_opts: [
                 channel_fns: %{
                   vector: fn _, _ -> {:unavailable, :down} end,
                   graph: fn _, _ -> {:unavailable, :down} end
                 }
               ]
             )

    assert [selected] = result.results
    assert selected.id == memory.id
    assert selected.policy_version == "current_context.v1"
    assert selected.trust == "candidate_inference"
    assert selected.effective_support
    assert selected.revision == DateTime.to_unix(memory.updated_at, :microsecond)
    assert selected.source_refs == Backplane.Memory.CurrentContext.result(memory).source_refs
    assert selected.evidence_refs != []
    assert selected.relevance_accepted
  end

  test "unknown calibration rejects semantic-only candidates and preserves useful lexical candidates after the count cap" do
    unrelated = candidate(content: "unrelated material")
    lexical = candidate(content: "query preference")

    assert {:ok, result} =
             Pipeline.run(Map.merge(@partition, %{query: "query"}),
               trace?: false,
               query_embedding_model: "uncalibrated-model",
               post_fusion_opts: [limit: 1],
               reranker_opts: [enabled: false],
               retriever_opts: [
                 channel_fns: %{
                   fts: fn _, _ -> {:ok, [{lexical, 0.01}]} end,
                   vector: fn _, _ -> {:ok, [{unrelated, 0.99}, {lexical, 0.2}]} end,
                   graph: fn _, _ -> {:unavailable, :down} end
                 }
               ]
             )

    assert [%{id: id}] = result.results
    assert id == lexical.id
  end

  test "FTS-only recall returns normalized provenance-bearing results within budget" do
    candidate = candidate(content: "bounded result", tokens: 5)

    candidate = %{
      candidate
      | source_host_id: "original-source-host",
        project: "/historical/project",
        repository_sources: [
          %{
            "repository_id" => "git.example/org/repo",
            "checkout_root" => "/one",
            "cwd" => "/one/sub"
          }
        ]
    }

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
    assert selected.source_host_id == "original-source-host"
    assert selected.project == "/historical/project"
    assert selected.repository_sources == candidate.repository_sources
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
            }, [stored]} =
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
    assert {:error, :incomplete_partition} = Pipeline.run(%{query: "q"})

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
               memory_space_id: @partition.memory_space_id,
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

  test "a slow semantic query pins the Settings model for selection and persisted trace despite a concurrent change" do
    alias Backplane.Memory.Memories.Memory
    setting = :ets.lookup(:backplane_settings, "memory.embed_model")

    calibration =
      for key <- ~w(memory.recall_relevance_vector_model memory.recall_relevance_vector_min),
          into: %{},
          do: {key, :ets.lookup(:backplane_settings, key)}

    previous = Application.get_env(:backplane_memory, :embed_model)
    model = "current-query-model"
    vector = [1.0 | List.duplicate(0.0, 2559)]

    on_exit(fn ->
      for {key, rows} <- calibration do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, rows)
      end

      :ets.delete(:backplane_settings, "memory.embed_model")
      Enum.each(setting, &:ets.insert(:backplane_settings, &1))

      if previous,
        do: Application.put_env(:backplane_memory, :embed_model, previous),
        else: Application.delete_env(:backplane_memory, :embed_model)
    end)

    memories =
      for {content, label, embedding} <- [
            {"Prefer bounded OTP workers.", model, [0.9, 0.1 | List.duplicate(0.0, 2558)]},
            {"Unrelated historical material.", "historical-model", vector}
          ] do
        {:ok, memory} =
          Memories.remember(
            content,
            Map.to_list(@partition) ++
              [
                agent_id: @partition.client_id,
                idempotency_scope: "pipeline-model-test",
                idempotency_key: label
              ]
          )

        repo().update!(Memory.embed_changeset(memory, embedding, label))
      end

    [wanted, historical] = memories
    :ets.insert(:backplane_settings, {"memory.recall_relevance_vector_model", model})
    :ets.insert(:backplane_settings, {"memory.recall_relevance_vector_min", 0.8})
    :ets.insert(:backplane_settings, {"memory.embed_model", model})
    Application.put_env(:backplane_memory, :embed_model, "stale-env-model")

    assert {:ok, result} =
             Pipeline.run(
               Map.merge(@partition, %{
                 query: "Which concurrency architecture should we choose?",
                 token_budget: 128
               }),
               trace?: true,
               retriever_opts: [
                 embed_fn: fn [_query], :query, [] ->
                   :ets.insert(
                     :backplane_settings,
                     {"memory.embed_model", "changed-during-query"}
                   )

                   Process.sleep(1_200)
                   {:ok, [vector]}
                 end
               ],
               post_fusion_opts: [limit: 1],
               reranker_opts: [enabled: false]
             )

    assert [%{id: id, source_ids: [_ | _]}] = result.results
    assert id == wanted.id
    assert result.channels.vector.status == :ok
    assert result.channels.fts.count == 0
    assert result.used_tokens <= result.token_budget
    assert {:ok, run, [stored]} = Store.get(result.recall_run_id, @partition)
    assert run.query_embedding_model == model
    assert run.channel_availability["vector"]
    assert run.channel_errors == %{"graph" => "unavailable"}
    assert stored.selected
    assert repo().get!(Memory, historical.id).embedding_model == "historical-model"
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
    {:ok, candidate} =
      canonical_recall_candidate(@partition, Keyword.get(opts, :content, "result"),
        token_estimate: Keyword.get(opts, :tokens, 1)
      )

    candidate
  end

  defp unique_supervisor,
    do: String.to_atom("pipeline_test_supervisor_#{System.unique_integer([:positive])}")
end
