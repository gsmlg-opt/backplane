defmodule Backplane.Memory.Memories.RelationClassifierTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Audit, Ingest}
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.RelationClassifier
  alias Backplane.Memory.Memories.Relations

  defmodule MockLLM do
    def classify_relation(source, target) do
      send(self(), {:classified, source, target})
      Process.get(:classifier_result)
    end
  end

  test "same normalized single-valued claim creates an evidence-backed duplicate candidate" do
    first = remember!("Backplane listens on 4220", claim(" Backplane ", "PORT", " 4220 "))
    second = remember!("The Backplane port is 4220", claim("backplane", "port", "4220"))

    assert :ok = RelationClassifier.process(second.id, model: nil)

    assert [relation] = Relations.list_relations(second.id)
    assert relation.classification == "duplicate"
    assert relation.status == "candidate"
    assert relation.confidence == 1.0
    assert {:ok, _correlation_id} = Ecto.UUID.cast(relation.correlation_id)

    assert MapSet.new(relation.evidence) ==
             MapSet.new(
               Enum.map(
                 Memories.list_evidence(relation.source_memory_id),
                 &%{
                   role: "source",
                   evidence_id: &1.id
                 }
               ) ++
                 Enum.map(
                   Memories.list_evidence(relation.target_memory_id),
                   &%{
                     role: "target",
                     evidence_id: &1.id
                   }
                 )
             )

    assert {:ok, %{lifecycle_state: "active", confidence: 1.0}} = Memories.trusted_get(first.id)

    assert {:ok, %{lifecycle_state: "active", confidence: 1.0}} =
             Memories.trusted_get(second.id)
  end

  test "claims that only share the first 500 characters are not deterministic duplicates" do
    prefix = String.duplicate("a", 500)
    first = remember!("first capped claim", claim(prefix <> "x", "port", "4220"))
    second = remember!("second capped claim", claim(prefix <> "y", "port", "4220"))

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert Relations.list_relations(first.id) == []
  end

  test "entity hint preprocessing scans a bounded prefix while retaining valid entries within it" do
    within_scan = List.duplicate(nil, 90) ++ ["backplane"]
    beyond_scan = List.duplicate(nil, 100) ++ ["backplane"]
    within = remember!("orchid quartz", %{"entities" => within_scan})
    beyond = remember!("velvet canyon", %{"entities" => beyond_scan})
    subject = remember!("backplane subject", %{"entities" => ["backplane"]})

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "extension", "confidence" => 0.8}}
    )

    assert :ok =
             RelationClassifier.process(subject.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert classified_source_contents([]) == [within.content]
    assert beyond.id != within.id
  end

  test "strong evidence-backed temporal replacement is atomically confirmed and audited" do
    older =
      remember!(
        "Backplane used port 4100",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2025-01-01T00:00:00Z",
          "valid_to" => "2025-12-31T23:59:59Z"
        })
      )

    newer =
      remember!(
        "Backplane uses port 4220",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-12-31T23:59:59Z"
        })
      )

    assert :ok = RelationClassifier.process(newer.id, model: nil)

    assert [relation] = Relations.list_relations(newer.id)
    assert relation.classification == "temporal_replacement"
    assert relation.source_memory_id == older.id
    assert relation.target_memory_id == newer.id
    assert relation.status == "confirmed"

    assert {:ok, %{lifecycle_state: "superseded", superseded_by: successor_id}} =
             Memories.trusted_get(older.id)

    assert successor_id == newer.id

    assert {:ok, %{lifecycle_state: "active", superseded_by: nil}} =
             Memories.trusted_get(newer.id)

    operations =
      older.id
      |> Backplane.Memory.Audit.list_for_target()
      |> Enum.map(& &1.operation)

    assert "memory_relation.candidate" in operations
    assert "memory_relation.resolve" in operations
  end

  test "automatic lifecycle relation audits inherit capture and remember correlations" do
    correlation_id = Ecto.UUID.generate()

    events =
      for {ordinal, value} <- [{1, "4100"}, {2, "4220"}] do
        captured =
          valid_event(%{
            "event_id" => Ecto.UUID.generate(),
            "host_id" => "host",
            "client_id" => "client",
            "scope" => "scope",
            "session_id" => "relation-trace",
            "sequence" => ordinal,
            "idempotency_key" => "relation-trace:#{ordinal}",
            "trace" => %{"correlation_id" => correlation_id},
            "payload" => %{"message" => "port #{value}"}
          })

        auth =
          ingest_auth_context("host", %{
            auth_token_id: "token",
            partition: %{scope: captured["scope"]}
          })

        assert {:ok, %{"results" => [%{"server_event_id" => event_id}]}} =
                 Ingest.ingest_batch(auth, %{
                   "batch_id" => Ecto.UUID.generate(),
                   "host_id" => "host",
                   "events" => [captured]
                 })

        event_id
      end

    [older_event, newer_event] = events

    older =
      remember!(
        "Backplane used port 4100",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2025-01-01T00:00:00Z",
          "valid_to" => "2025-12-31T23:59:59Z"
        }),
        client_id: "client",
        idempotency_scope: "relation-trace",
        idempotency_key: "older",
        evidence: [
          %{
            source_event_id: older_event,
            host_id: "host",
            evidence_kind: "derives",
            support_score: 1.0
          }
        ]
      )

    newer =
      remember!(
        "Backplane uses port 4220",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-12-31T23:59:59Z"
        }),
        client_id: "client",
        idempotency_scope: "relation-trace",
        idempotency_key: "newer",
        evidence: [
          %{
            source_event_id: newer_event,
            host_id: "host",
            evidence_kind: "derives",
            support_score: 1.0
          }
        ]
      )

    assert :ok = RelationClassifier.process(newer.id, model: nil)
    assert [relation] = Relations.list_relations(newer.id)

    request_ids =
      [older, newer]
      |> Enum.flat_map(&Memories.list_evidence(&1.id))
      |> Enum.filter(&(&1.source_type == "request"))
      |> Enum.map(& &1.source_id)
      |> Enum.sort()

    assert relation.correlation_id in request_ids

    audits =
      Audit.list_for_target(older.id)
      |> Enum.filter(
        &(&1.operation in ~w(memory_relation.candidate memory_relation.policy memory_relation.resolve))
      )

    assert Enum.sort(Enum.map(audits, & &1.operation)) ==
             Enum.sort(
               ~w(memory_relation.candidate memory_relation.policy memory_relation.resolve)
             )

    for audit <- audits do
      metadata = audit.metadata
      assert metadata["host_id"] == "host"
      assert metadata["client_id"] == "client"
      assert metadata["scope"] == "scope"
      assert metadata["namespace"] == "private"
      assert metadata["request_ids"] == request_ids
      assert metadata["request_id"] in request_ids
      assert metadata["correlation_ids"] == [correlation_id]
      assert is_binary(metadata["result"])
      refute inspect(metadata) =~ "Backplane uses port"
    end
  end

  test "different single values with overlapping validity create a contradiction candidate" do
    first =
      remember!(
        "Backplane uses port 4100",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-06-30T23:59:59Z"
        })
      )

    second =
      remember!(
        "Backplane uses port 4220",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-06-01T00:00:00Z",
          "valid_to" => "2026-12-31T23:59:59Z"
        })
      )

    assert :ok = RelationClassifier.process(second.id, model: nil)

    assert [relation] = Relations.list_relations(second.id)
    assert relation.classification == "contradiction"

    assert MapSet.new([relation.source_memory_id, relation.target_memory_id]) ==
             MapSet.new([first.id, second.id])

    assert relation.status == "candidate"
    assert {:ok, %{lifecycle_state: "disputed"}} = Memories.trusted_get(first.id)
    assert {:ok, %{lifecycle_state: "disputed"}} = Memories.trusted_get(second.id)

    assert [policy] =
             first.id
             |> Backplane.Memory.Audit.list_for_target()
             |> Enum.filter(&(&1.operation == "memory_relation.policy"))

    assert policy.metadata["outcome"] == "review"
  end

  test "a bounded old interval can be replaced by an open-ended newer interval" do
    older =
      remember!(
        "Backplane used port 4100",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2025-01-01T00:00:00Z",
          "valid_to" => "2025-12-31T23:59:59Z"
        })
      )

    newer =
      remember!(
        "Backplane uses port 4220",
        claim("backplane", "port", "4220", %{"valid_from" => "2026-01-01T00:00:00Z"})
      )

    assert :ok = RelationClassifier.process(newer.id, model: nil)
    assert [relation] = Relations.list_relations(newer.id)
    assert relation.classification == "temporal_replacement"
    assert relation.source_memory_id == older.id
    assert relation.target_memory_id == newer.id
  end

  test "an open-ended interval contradicts a differing overlapping interval" do
    open_ended =
      remember!(
        "Backplane uses port 4100",
        claim("backplane", "port", "4100", %{"valid_from" => "2025-01-01T00:00:00Z"})
      )

    overlapping =
      remember!(
        "Backplane uses port 4220",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-12-31T23:59:59Z"
        })
      )

    assert :ok = RelationClassifier.process(overlapping.id, model: nil)
    assert [relation] = Relations.list_relations(open_ended.id)
    assert relation.classification == "contradiction"
  end

  test "missing validity retains an evidence-backed contradiction for review" do
    first = remember!("Backplane uses port 4100", claim("backplane", "port", "4100"))
    second = remember!("Backplane uses port 4220", claim("backplane", "port", "4220"))

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "contradiction", "confidence" => 0.95}}
    )

    assert :ok =
             RelationClassifier.process(second.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert_received {:classified, _, _}
    assert [relation] = Relations.list_relations(first.id)
    assert relation.classification == "contradiction"
    assert relation.status == "candidate"
    assert relation.evidence != []
    assert {:ok, %{lifecycle_state: "disputed"}} = Memories.trusted_get(first.id)
    assert {:ok, %{lifecycle_state: "disputed"}} = Memories.trusted_get(second.id)
  end

  test "insufficient support remains reviewable and later strong evidence confirms replacement" do
    weak = %{evidence_kind: "supports", support_score: 0.4}

    older =
      remember!(
        "weak older",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2025-01-01T00:00:00Z",
          "valid_to" => "2025-12-31T23:59:59Z"
        }),
        evidence: [Map.merge(weak, %{source_session_id: "weak-old", host_id: "host"})]
      )

    newer =
      remember!(
        "weak newer",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-01-01T00:00:00Z"
        }),
        evidence: [Map.merge(weak, %{source_session_id: "weak-new", host_id: "host"})]
      )

    assert :ok = RelationClassifier.process(newer.id, model: nil)
    assert [candidate] = Relations.list_relations(older.id)
    assert candidate.status == "candidate"
    assert length(candidate.evidence) >= 2
    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(older.id)

    strong = %{evidence_kind: "confirms", support_score: 1.0}

    assert {:ok, ^older} =
             Memories.remember("weak older",
               agent_id: "agent",
               host_id: "host",
               scope: "scope",
               namespace: "private",
               metadata: older.metadata,
               evidence: [Map.merge(strong, %{source_session_id: "strong-old", host_id: "host"})]
             )

    assert {:ok, ^newer} =
             Memories.remember("weak newer",
               agent_id: "agent",
               host_id: "host",
               scope: "scope",
               namespace: "private",
               metadata: newer.metadata,
               evidence: [Map.merge(strong, %{source_session_id: "strong-new", host_id: "host"})]
             )

    assert :ok = RelationClassifier.process(newer.id, model: nil)
    relations = Relations.list_relations(older.id)
    assert Enum.count(relations, &(&1.status == "candidate")) == 1
    assert Enum.count(relations, &(&1.status == "confirmed")) == 1

    assert {:ok, %{lifecycle_state: "superseded", superseded_by: successor}} =
             Memories.trusted_get(older.id)

    assert successor == newer.id
  end

  test "model can create an extension candidate for normalized entity overlap" do
    first = remember!("Backplane has an MCP endpoint", %{"entities" => [" Backplane "]})
    second = remember!("The endpoint supports streaming", %{"entities" => ["backplane"]})

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "extension", "confidence" => 0.8}}
    )

    assert :ok =
             RelationClassifier.process(second.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert_received {:classified, source_descriptor, target_descriptor}
    assert source_descriptor["content"] == "Backplane has an MCP endpoint"
    assert target_descriptor["content"] == "The endpoint supports streaming"

    assert [%{"evidence_kind" => "supports", "support_score" => 1.0}] =
             source_descriptor["evidence"]

    assert [relation] = Relations.list_relations(second.id)
    assert relation.classification == "extension"
    assert first.id in [relation.source_memory_id, relation.target_memory_id]
    assert relation.confidence == 0.8
    assert relation.classifier_model == "test-model"
    assert relation.status == "candidate"
  end

  test "low-confidence temporal replacement remains review-only and non-destructive" do
    older =
      remember!("older low-confidence value", %{
        "valid_from" => "2025-01-01T00:00:00Z",
        "valid_to" => "2025-12-31T23:59:59Z"
      })

    newer = remember!("newer low-confidence value", %{"valid_from" => "2026-01-01T00:00:00Z"})

    attrs = %{
      classification: "temporal_replacement",
      confidence: 0.5,
      classifier_model: "test-model",
      classifier_version: "relation-v1",
      input_revision: "low-confidence-revision",
      source_evidence_ids: Enum.map(Memories.list_evidence(older.id), & &1.id),
      target_evidence_ids: Enum.map(Memories.list_evidence(newer.id), & &1.id)
    }

    assert {:ok, _candidate} = Relations.apply_classifier(older.id, newer.id, attrs)
    assert [relation] = Relations.list_relations(newer.id)
    assert relation.status == "candidate"

    assert {:ok, %{lifecycle_state: "active", superseded_by: nil}} =
             Memories.trusted_get(older.id)

    assert {:ok, %{lifecycle_state: "active", superseded_by: nil}} =
             Memories.trusted_get(newer.id)
  end

  test "content-only paraphrases have a bounded lexical path to the model" do
    first = remember!("Backplane exposes MCP tools through its gateway", %{})
    second = remember!("The Backplane MCP endpoint extends tool discovery", %{})

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "extension", "confidence" => 0.85}}
    )

    assert :ok =
             RelationClassifier.process(second.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert_received {:classified, %{"content" => first_content}, %{"content" => second_content}}
    assert first_content == first.content
    assert second_content == second.content
    assert [relation] = Relations.list_relations(first.id)
    assert relation.classification == "extension"
  end

  test "an interval with equal endpoints is invalid for deterministic classification" do
    first =
      remember!(
        "Backplane used port 4100 for an invalid zero interval",
        claim("backplane", "port", "4100", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-01-01T00:00:00Z"
        })
      )

    second =
      remember!(
        "Backplane uses port 4220 for an invalid zero interval",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-01-01T00:00:00Z"
        })
      )

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert Relations.list_relations(first.id) == []
  end

  test "retrying the same classification reuses its durable candidate and correlation" do
    first = remember!("Backplane listens on 4220", claim("backplane", "port", "4220"))
    second = remember!("The Backplane port is 4220", claim("backplane", "port", "4220"))

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert [original] = Relations.list_relations(first.id)

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert [retried] = Relations.list_relations(first.id)
    assert retried.id == original.id
    assert retried.correlation_id == original.correlation_id
  end

  test "model candidates stay inside the exact memory partition" do
    shared = %{"entities" => ["backplane"], "project" => "project-a"}

    peer = remember!("same partition", shared, client_id: "client-a")
    remember!("different scope", shared, scope: "other", client_id: "client-a")
    remember!("different namespace", shared, namespace: "shared", client_id: "client-a")
    remember!("different type", shared, type: "procedural", client_id: "client-a")
    remember!("different project", %{shared | "project" => "project-b"}, client_id: "client-a")
    remember!("different client", shared, client_id: "client-b")
    remember!("different host", shared, host_id: "other-host", client_id: "client-a")
    subject = remember!("partition subject", shared, client_id: "client-a")

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "extension", "confidence" => 0.7}}
    )

    assert :ok =
             RelationClassifier.process(subject.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert_received {:classified, %{"content" => peer_content}, %{"content" => subject_content}}
    assert peer_content == peer.content
    assert subject_content == subject.content
    refute_received {:classified, _, _}
    assert [_relation] = Relations.list_relations(subject.id)
  end

  test "model comparison evaluation is deterministically capped at five peers" do
    metadata = %{"entities" => ["backplane"]}

    for index <- 1..25 do
      remember!("bounded peer #{index}", metadata)
    end

    subject = remember!("bounded subject", metadata)

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "unrelated", "confidence" => 1.0}}
    )

    opts = [model: "test-model", llm_module: MockLLM]
    assert :ok = RelationClassifier.process(subject.id, opts)
    first_contents = classified_source_contents([])
    assert length(first_contents) == 5

    assert :ok = RelationClassifier.process(subject.id, opts)
    assert classified_source_contents([]) == first_contents
  end

  test "newer unrelated peers cannot hide an older structured-claim match" do
    older = remember!("older exact claim", claim("backplane", "port", "4220"))

    for index <- 1..25 do
      remember!("newer unrelated #{index}", %{})
    end

    subject = remember!("current exact claim", claim("backplane", "port", "4220"))

    assert :ok = RelationClassifier.process(subject.id, model: nil)
    assert [relation] = Relations.list_relations(subject.id)
    assert relation.classification == "duplicate"
    assert older.id in [relation.source_memory_id, relation.target_memory_id]
  end

  test "processing is limited to semantic and procedural memories" do
    pairs =
      for type <- ~w(working episodic semantic procedural), into: %{} do
        first =
          remember!("#{type} first", claim("backplane", "port", "4220"), type: type)

        second =
          remember!("#{type} second", claim("backplane", "port", "4220"), type: type)

        assert :ok = RelationClassifier.process(second.id, model: nil)
        {type, {first, second}}
      end

    for type <- ~w(working episodic) do
      {first, _second} = pairs[type]
      assert Relations.list_relations(first.id) == []
    end

    for type <- ~w(semantic procedural) do
      {first, _second} = pairs[type]
      assert [_relation] = Relations.list_relations(first.id)
    end
  end

  test "a model peer error does not prevent a later deterministic candidate" do
    first = remember!("first peer", %{})
    second = remember!("second peer", %{})
    [model_peer, deterministic_peer] = Enum.sort_by([first, second], & &1.id)

    model_peer
    |> Ecto.Changeset.change(
      metadata: %{
        "claim" => %{
          "subject" => "backplane",
          "predicate" => "port",
          "value" => "unknown",
          "cardinality" => "multiple"
        },
        "entities" => ["backplane"]
      }
    )
    |> repo().update!()

    deterministic_peer
    |> Ecto.Changeset.change(
      metadata:
        claim("backplane", "port", "4100", %{
          "valid_from" => "2026-01-01T00:00:00Z",
          "valid_to" => "2026-12-31T23:59:59Z"
        })
    )
    |> repo().update!()

    subject =
      remember!(
        "contradicting subject",
        claim("backplane", "port", "4220", %{
          "valid_from" => "2026-06-01T00:00:00Z",
          "valid_to" => "2027-01-01T00:00:00Z"
        })
      )

    Process.put(:classifier_result, {:error, :provider_down})

    assert {:error, :provider_down} =
             RelationClassifier.process(subject.id,
               model: "test-model",
               llm_module: MockLLM
             )

    assert [relation] = Relations.list_relations(deterministic_peer.id)
    assert relation.classification == "contradiction"
  end

  test "equal tags alone do not create a model candidate" do
    first = remember!("alpha memory", %{}, tags: ["shared-tag"])
    second = remember!("omega record", %{}, tags: ["shared-tag"])

    Process.put(
      :classifier_result,
      {:ok, %{"classification" => "extension", "confidence" => 0.9}}
    )

    assert :ok =
             RelationClassifier.process(second.id,
               model: "test-model",
               llm_module: MockLLM
             )

    refute_received {:classified, _, _}
    assert Relations.list_relations(first.id) == []
  end

  test "new endpoint evidence produces a new canonical input revision" do
    first = remember!("Backplane listens on 4220", claim("backplane", "port", "4220"))
    second = remember!("The Backplane port is 4220", claim("backplane", "port", "4220"))

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert [original] = Relations.list_relations(first.id)

    assert {:ok, ^first} =
             Memories.remember("Backplane listens on 4220",
               agent_id: "agent",
               host_id: "host",
               scope: "scope",
               namespace: "private",
               metadata: claim("backplane", "port", "4220")
             )

    assert :ok = RelationClassifier.process(second.id, model: nil)
    assert relations = Relations.list_relations(first.id)
    assert length(relations) == 2
    assert MapSet.size(MapSet.new(relations, & &1.input_revision)) == 2
    assert original.input_revision in Enum.map(relations, & &1.input_revision)
  end

  test "concurrent retries converge on one durable candidate" do
    first = remember!("Backplane listens on 4220", claim("backplane", "port", "4220"))
    second = remember!("The Backplane port is 4220", claim("backplane", "port", "4220"))

    results =
      1..8
      |> Task.async_stream(fn _ -> RelationClassifier.process(second.id, model: nil) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert [_relation] = Relations.list_relations(first.id)

    operations =
      first.id
      |> Backplane.Memory.Audit.list_for_target()
      |> Enum.frequencies_by(& &1.operation)

    assert operations["memory_relation.candidate"] == 1
    assert operations["memory_relation.policy"] == 1
  end

  defp remember!(content, metadata, opts \\ []) do
    {:ok, memory} =
      Memories.remember(
        content,
        Keyword.merge(
          [
            agent_id: "agent",
            host_id: "host",
            scope: "scope",
            namespace: "private",
            metadata: metadata
          ],
          opts
        )
      )

    memory
  end

  defp classified_source_contents(contents) do
    receive do
      {:classified, %{"content" => source_content}, _target} ->
        classified_source_contents([source_content | contents])
    after
      0 -> Enum.reverse(contents)
    end
  end

  defp claim(subject, predicate, value, extra \\ %{}) do
    Map.merge(
      %{
        "claim" => %{
          "subject" => subject,
          "predicate" => predicate,
          "value" => value,
          "cardinality" => "single"
        },
        "entities" => [subject]
      },
      extra
    )
  end
end
