defmodule Backplane.Memory.Memories.VerificationTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Memories.Relation
  alias Backplane.Memory.Memories.Relations
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{EpisodicWorker, ProceduralWorker, SummaryWorker}

  defmodule MockLLM do
    def extract_facts(content) do
      suffix = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:ok, ["verified automatic fact #{suffix}"]}
    end

    def extract_procedures(_content), do: {:ok, ["verified automatic procedure"]}
  end

  setup do
    previous_llm = Application.get_env(:backplane_memory, :llm_module)
    setting = :ets.lookup(:backplane_settings, "memory.llm_model")
    Application.put_env(:backplane_memory, :llm_module, MockLLM)
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})

    on_exit(fn ->
      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_module, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_module)

      case setting do
        [] -> :ets.delete(:backplane_settings, "memory.llm_model")
        [entry] -> :ets.insert(:backplane_settings, entry)
      end
    end)

    :ok
  end

  test "canonical events through summary and automatic memory produce a complete bounded chain" do
    host_id = "verify-host"
    session_id = "verify-session"

    for {sequence, type, message} <- [
          {1, "agent.session.started", "start"},
          {2, "agent.prompt.submitted", "durable source"},
          {3, "agent.session.ended", "done"}
        ] do
      ingest!(event(host_id, session_id, sequence, type, message))
    end

    assert {:ok, projection} = Rebuild.session(host_id, session_id)

    assert :ok =
             SummaryWorker.perform(%Oban.Job{
               args: %{
                 "host_id" => host_id,
                 "session_id" => session_id,
                 "processing_version" => "summary-v1",
                 "input_revision" => projection.input_revision
               }
             })

    summary = repo().one!(Backplane.Memory.Summaries.Summary)
    assert :ok = EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => summary.id}})

    memory =
      repo().one!(
        from(m in Memory,
          where: m.memory_type == "semantic",
          order_by: [asc: m.inserted_at],
          limit: 1
        )
      )

    partition = %{
      host_id: host_id,
      client_id: "host:#{host_id}",
      scope: "verify-scope",
      namespace: "private"
    }

    assert Map.take(memory, [:host_id, :client_id, :scope, :namespace]) == partition
    assert {:ok, verification} = Memories.verify(memory.id, partition)

    assert verification.memory.memory_type == "semantic"
    assert verification.lifecycle_state == "active"
    assert [%{processing_version: "summary-v1", source_complete: true}] = verification.summaries
    assert length(verification.summary_event_links) == 3
    assert length(verification.source_events) == 3
    assert Enum.map(verification.source_events, & &1.sequence) == [1, 2, 3]
    assert Enum.all?(verification.provenance_roots, & &1.resolved)

    assert Map.take(verification.bounds, [
             :depth,
             :evidence_limit,
             :relation_limit,
             :source_limit,
             :audit_limit,
             :cycle_safe
           ]) == %{
             depth: 2,
             evidence_limit: 100,
             relation_limit: 100,
             source_limit: 200,
             audit_limit: 100,
             cycle_safe: true
           }

    assert verification.bounds.evidence.truncated == false
    assert verification.bounds.audit.truncated == false

    for ordinal <- 2..10 do
      next_session_id = "#{session_id}-#{ordinal}"

      for {sequence, type, message} <- [
            {1, "agent.session.started", "start #{ordinal}"},
            {2, "agent.prompt.submitted", "durable source #{ordinal}"},
            {3, "agent.session.ended", "done #{ordinal}"}
          ] do
        ingest!(event(host_id, next_session_id, sequence, type, message))
      end

      assert {:ok, next_projection} = Rebuild.session(host_id, next_session_id)

      assert :ok =
               SummaryWorker.perform(%Oban.Job{
                 args: %{
                   "host_id" => host_id,
                   "session_id" => next_session_id,
                   "processing_version" => "summary-v1",
                   "input_revision" => next_projection.input_revision
                 }
               })

      next_summary =
        repo().one!(from(s in Summary, where: s.subject_id == ^next_projection.subject_id))

      assert :ok = EpisodicWorker.perform(%Oban.Job{args: %{"summary_id" => next_summary.id}})
    end

    assert :ok = ProceduralWorker.perform(%Oban.Job{args: %{}})

    procedure =
      repo().one!(
        from(m in Memory,
          where: m.memory_type == "procedural" and m.content == "verified automatic procedure"
        )
      )

    assert Map.take(procedure, [:host_id, :client_id, :scope, :namespace]) == partition
    assert {:ok, procedure_verification} = Memories.verify(procedure.id, partition)
    assert procedure_verification.evidence_count == 11
    assert length(procedure_verification.summaries) == 10
    assert length(procedure_verification.summary_event_links) == 30
    assert length(procedure_verification.source_events) == 30
    assert Enum.all?(procedure_verification.provenance_roots, & &1.resolved)
    assert procedure_verification.bounds.evidence.truncated == false
    assert procedure_verification.bounds.source_events.truncated == false
  end

  test "cross-partition evidence never traverses into a foreign canonical event" do
    foreign = event("foreign-host", "foreign-session", 1, "agent.prompt.submitted", "secret")
    ingest!(foreign)

    assert {:ok, memory} =
             Memories.remember("partition-safe",
               type: "semantic",
               host_id: "owner-host",
               client_id: "codex-cli",
               scope: "verify-scope",
               namespace: "private",
               agent_id: "agent",
               evidence: [
                 %{
                   source_event_id: foreign["event_id"],
                   host_id: "owner-host",
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    partition = %{
      host_id: "owner-host",
      client_id: "codex-cli",
      scope: "verify-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(memory.id, partition)
    assert verification.source_events == []

    assert Enum.any?(
             verification.provenance_roots,
             &(&1.source_type == "event" and not &1.resolved)
           )
  end

  test "forged session roots stay unresolved and evidence truncation is explicit" do
    opts = [
      type: "semantic",
      host_id: "bounded-host",
      client_id: "bounded-client",
      scope: "bounded-scope",
      namespace: "private",
      agent_id: "agent"
    ]

    assert {:ok, memory} =
             Memories.remember(
               "bounded evidence",
               opts ++
                 [
                   idempotency_scope: "verify",
                   idempotency_key: "0",
                   evidence: [
                     %{
                       source_session_id: "forged",
                       host_id: "bounded-host",
                       evidence_kind: "derives",
                       support_score: 1.0
                     }
                   ]
                 ]
             )

    for index <- 1..105 do
      assert {:ok, ^memory} =
               Memories.remember(
                 "bounded evidence",
                 opts ++
                   [
                     idempotency_scope: "verify",
                     idempotency_key: Integer.to_string(index)
                   ]
               )
    end

    partition = %{
      host_id: "bounded-host",
      client_id: "bounded-client",
      scope: "bounded-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(memory.id, partition)
    assert verification.evidence_count == 107
    assert length(verification.evidence) == 100

    assert verification.bounds.evidence == %{
             total_count: 107,
             returned_count: 100,
             truncated: true
           }

    assert Enum.any?(
             verification.provenance_roots,
             &(&1.source_type == "session" and not &1.resolved)
           )
  end

  test "relation graph traverses an A-B-C-A cycle once with evidence, requests, and audit" do
    opts = [
      type: "semantic",
      host_id: "cycle-host",
      client_id: "cycle-client",
      scope: "cycle-scope",
      namespace: "private",
      agent_id: "agent",
      idempotency_scope: "cycle"
    ]

    memories =
      for {content, key} <- [{"A", "a"}, {"B", "b"}, {"C", "c"}] do
        assert {:ok, memory} =
                 Memories.remember(content, opts ++ [idempotency_key: key])

        memory
      end

    [a, b, c] = memories

    relations =
      for {source, target, revision} <- [
            {a, b, "a-b"},
            {b, c, "b-c"},
            {a, c, "c-a"}
          ] do
        assert {:ok, relation} =
                 Relations.create_candidate(source.id, target.id, %{
                   classification: "extension",
                   confidence: 0.9,
                   classifier_model: "test-model",
                   classifier_version: "v1",
                   input_revision: revision,
                   source_evidence_ids: evidence_ids(source),
                   target_evidence_ids: evidence_ids(target)
                 })

        relation
      end

    partition = %{
      host_id: "cycle-host",
      client_id: "cycle-client",
      scope: "cycle-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(a.id, partition)
    graph = verification.graph

    assert graph.visited_memory_ids == Enum.sort(Enum.map(memories, & &1.id))
    assert Enum.sort(Enum.map(graph.links, & &1.id)) == Enum.sort(Enum.map(relations, & &1.id))
    assert length(graph.relation_evidence) == 6
    assert length(graph.inherited_evidence) == 2
    assert Enum.all?(graph.inherited_sources.roots, & &1.resolved)
    assert Enum.sort(Enum.map(graph.inherited_sources.nodes, & &1.type)) == ["request", "request"]
    assert Enum.any?(graph.audit_decisions, &(&1.operation == "memory_relation.candidate"))
    assert graph.bounds.nodes == %{total_count: 3, returned_count: 3, truncated: false}
    assert graph.bounds.edges == %{total_count: 3, returned_count: 3, truncated: false}

    assert graph.bounds.relation_evidence == %{
             total_count: 6,
             returned_count: 6,
             truncated: false
           }

    assert graph.bounds.inherited_evidence == %{
             total_count: 2,
             returned_count: 2,
             truncated: false
           }
  end

  test "relation graph reaches a depth-two node without inventing a root edge" do
    opts = [
      type: "semantic",
      host_id: "depth-host",
      client_id: "depth-client",
      scope: "depth-scope",
      namespace: "private",
      agent_id: "agent",
      idempotency_scope: "depth"
    ]

    [a, b, c] =
      for {content, key} <- [{"depth A", "a"}, {"depth B", "b"}, {"depth C", "c"}] do
        assert {:ok, memory} = Memories.remember(content, opts ++ [idempotency_key: key])
        memory
      end

    for {source, target, revision} <- [{a, b, "depth-a-b"}, {b, c, "depth-b-c"}] do
      assert {:ok, _relation} =
               Relations.create_candidate(source.id, target.id, %{
                 classification: "extension",
                 confidence: 0.9,
                 classifier_model: "test-model",
                 classifier_version: "v1",
                 input_revision: revision,
                 source_evidence_ids: evidence_ids(source),
                 target_evidence_ids: evidence_ids(target)
               })
    end

    partition = %{
      host_id: "depth-host",
      client_id: "depth-client",
      scope: "depth-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(a.id, partition)
    assert c.id in verification.graph.visited_memory_ids
    refute Enum.any?(verification.graph.links, &(&1.source_id == a.id and &1.target_id == c.id))
  end

  test "session provenance preserves colons in the structural session id" do
    host_id = "colon-host"
    session_id = "workspace:thread:42"
    ingest!(event(host_id, session_id, 1, "agent.prompt.submitted", "colon source"))
    assert {:ok, _projection} = Rebuild.session(host_id, session_id)

    assert {:ok, memory} =
             Memories.remember("colon session evidence",
               type: "semantic",
               host_id: host_id,
               client_id: "host:#{host_id}",
               scope: "verify-scope",
               namespace: "private",
               agent_id: "agent",
               evidence: [
                 %{
                   source_session_id: session_id,
                   host_id: host_id,
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    partition = %{
      host_id: host_id,
      client_id: "host:#{host_id}",
      scope: "verify-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(memory.id, partition)

    assert Enum.any?(
             verification.provenance_roots,
             &(&1.source_type == "session" and &1.resolved)
           )
  end

  test "high-degree graph reports exact omissions and never returns dangling edges" do
    opts = [
      type: "semantic",
      host_id: "star-host",
      client_id: "star-client",
      scope: "star-scope",
      namespace: "private",
      agent_id: "agent"
    ]

    assert {:ok, root} = Memories.remember("star root", opts)

    peers =
      for index <- 1..105 do
        assert {:ok, peer} = Memories.remember("star peer #{index}", opts)
        peer
      end

    now = DateTime.utc_now()

    rows =
      Enum.map(peers, fn peer ->
        %{
          id: Ecto.UUID.generate(),
          source_memory_id: min(root.id, peer.id),
          target_memory_id: max(root.id, peer.id),
          domain: "knowledge",
          relation_type: "extends",
          classification: "extension",
          confidence: 0.9,
          status: "candidate",
          classifier_model: "test-model",
          classifier_version: "v1",
          input_revision: Ecto.UUID.generate(),
          correlation_id: Ecto.UUID.generate(),
          created_at: now
        }
      end)

    assert {105, nil} = repo().insert_all(Relation, rows)

    partition = %{
      host_id: "star-host",
      client_id: "star-client",
      scope: "star-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(root.id, partition)
    graph = verification.graph
    returned = MapSet.new(graph.visited_memory_ids)

    assert graph.bounds.nodes == %{total_count: 106, returned_count: 100, truncated: true}
    assert graph.bounds.omitted_memory_count == 6
    assert length(graph.bounds.omitted_memory_ids) == 6
    assert graph.bounds.edges.total_count == 105
    assert graph.bounds.edges.truncated

    assert Enum.all?(graph.links, fn link ->
             MapSet.member?(returned, link.source_id) and MapSet.member?(returned, link.target_id)
           end)
  end

  test "same-host foreign-client remember request remains unresolved" do
    assert {:ok, foreign} =
             Memories.remember("foreign request owner",
               type: "semantic",
               host_id: "shared-host",
               client_id: "foreign-client",
               scope: "shared-scope",
               namespace: "private",
               agent_id: "agent"
             )

    foreign_request =
      Memories.list_evidence(foreign.id)
      |> Enum.find(&(&1.source_type == "request"))

    assert {:ok, owner} =
             Memories.remember("owner with forged request root",
               type: "semantic",
               host_id: "shared-host",
               client_id: "owner-client",
               scope: "shared-scope",
               namespace: "private",
               agent_id: "agent",
               evidence: [
                 %{
                   source_request_id: foreign_request.source_id,
                   host_id: "shared-host",
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    partition = %{
      host_id: "shared-host",
      client_id: "owner-client",
      scope: "shared-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(owner.id, partition)

    assert Enum.any?(
             verification.provenance_roots,
             &(&1.source_type == "request" and &1.source_id == foreign_request.source_id and
                 not &1.resolved)
           )
  end

  test "same-host foreign-client summary with valid canonical links remains unresolved" do
    host_id = "summary-shared-host"
    session_id = "foreign-summary-session"
    foreign_event = event(host_id, session_id, 1, "agent.prompt.submitted", "foreign summary")
    ingest!(foreign_event)
    assert {:ok, projection} = Rebuild.session(host_id, session_id)

    foreign_summary =
      %Summary{}
      |> Summary.changeset(%{
        session_id: session_id,
        project: "",
        content: "foreign canonical summary",
        observation_count: 1,
        subject_id: projection.subject_id,
        host_id: host_id,
        processing_version: "foreign-v1",
        input_revision: projection.input_revision,
        output_revision: String.duplicate("a", 64)
      })
      |> repo().insert!()

    repo().insert_all(SourceEvent, [
      %{
        summary_id: foreign_summary.id,
        event_id: foreign_event["event_id"],
        host_id: host_id,
        session_id: session_id,
        inserted_at: DateTime.utc_now()
      }
    ])

    assert {:ok, owner} =
             Memories.remember("owner with forged summary root",
               type: "semantic",
               host_id: host_id,
               client_id: "owner-client",
               scope: "verify-scope",
               namespace: "private",
               agent_id: "agent",
               evidence: [
                 %{
                   source_summary_id: foreign_summary.id,
                   host_id: host_id,
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    partition = %{
      host_id: host_id,
      client_id: "owner-client",
      scope: "verify-scope",
      namespace: "private"
    }

    assert {:ok, verification} = Memories.verify(owner.id, partition)
    assert verification.summaries == []
    assert verification.summary_event_links == []
    assert verification.source_events == []

    assert Enum.any?(
             verification.provenance_roots,
             &(&1.source_type == "summary" and &1.source_id == foreign_summary.id and
                 not &1.resolved)
           )
  end

  test "graph query cancellation returns an explicit incomplete graph without raising" do
    previous = Application.get_env(:backplane_memory, :verification_graph_query)

    Application.put_env(
      :backplane_memory,
      :verification_graph_query,
      fn _sql, _params, _opts ->
        {:error, %DBConnection.ConnectionError{message: "secret sql"}}
      end
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :verification_graph_query, previous),
        else: Application.delete_env(:backplane_memory, :verification_graph_query)
    end)

    assert {:ok, memory} =
             Memories.remember("timeout-safe",
               type: "semantic",
               host_id: "timeout-host",
               client_id: "timeout-client",
               scope: "timeout-scope",
               namespace: "private",
               agent_id: "agent"
             )

    assert {:ok, verification} =
             Memories.verify(memory.id, %{
               host_id: "timeout-host",
               client_id: "timeout-client",
               scope: "timeout-scope",
               namespace: "private"
             })

    assert verification.graph.status == "timed_out"
    assert verification.graph.incomplete
    assert verification.graph.bounds.nodes.total_count == nil
    assert verification.graph.bounds.nodes.truncated
    assert verification.graph.links == []
    refute inspect(verification.graph) =~ "secret sql"
  end

  defp event(host_id, session_id, sequence, type, message) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "sequence" => sequence,
      "scope" => "verify-scope",
      "event_type" => type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}",
      "payload" => %{"message" => message}
    })
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(event["host_id"], %{
                 auth_token_id: "token",
                 partition: %{scope: event["scope"]}
               }),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => event["host_id"],
                 "events" => [event]
               }
             )
  end

  defp evidence_ids(memory), do: Enum.map(Memories.list_evidence(memory.id), & &1.id)
end
