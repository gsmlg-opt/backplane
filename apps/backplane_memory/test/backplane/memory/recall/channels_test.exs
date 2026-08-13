defmodule Backplane.Memory.Recall.ChannelsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Facets.{Dimension, Facet}
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedObservation, ProjectedSession}
  alias Backplane.Memory.Recall.{Channels, QueryPlan}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.GraphExtractWorker

  @partition %{host_id: "host-a", client_id: "client-a", scope: "team", namespace: "private"}
  @foreign %{host_id: "host-b", client_id: "client-a", scope: "team", namespace: "private"}
  @dim 2560

  defmodule GraphLLM do
    def extract_graph(_contents),
      do: {:ok, %{nodes: [%{type: "Concept", name: "WriterBackplane"}], edges: []}}
  end

  test "FTS applies exact partition, project, and facets before rank and limit without writeback" do
    repo().insert!(Dimension.changeset(%Dimension{}, %{name: "topic"}))
    wanted = memory("deterministic recall architecture", @partition, project: "backplane")

    repo().insert!(
      Facet.changeset(%Facet{}, %{memory_id: wanted.id, dimension: "topic", value: "recall"})
    )

    for index <- 1..8 do
      memory("deterministic recall architecture #{index}", @foreign, project: "backplane")
    end

    {:ok, plan} =
      QueryPlan.new(
        Map.merge(@partition, %{
          query: "deterministic recall",
          project: "backplane",
          facets: [%{"dimension" => "topic", "value" => "recall"}]
        })
      )

    assert {:ok, [{candidate, score}]} = Channels.fts(plan, 1)
    assert candidate.id == wanted.id
    assert candidate.host_id == @partition.host_id
    assert [source_id] = candidate.source_ids
    assert candidate.source_refs == [%{type: :request, id: source_id}]
    assert repo().get!(RememberRequest, source_id).memory_id == wanted.id
    assert candidate.evidence_count == 1
    assert score > 0.0
    assert repo().get!(Memory, wanted.id).access_count == 0
  end

  test "FTS drops forged cross-partition event evidence from candidate provenance" do
    wanted = memory("partition-safe evidence canary", @partition)
    foreign_event = Ecto.UUID.generate()
    insert_event(foreign_event, @foreign, "foreign-evidence-session")

    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: wanted.id,
        source_event_id: foreign_event,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(@partition, %{query: "partition-safe evidence canary"}))

    assert {:ok, [{candidate, _score}]} = Channels.fts(plan, 10)
    refute foreign_event in candidate.source_ids
    assert candidate.evidence_count == 1
  end

  test "FTS fails closed for a derived memory without durable evidence" do
    memory("unproven derived canary", @partition, provenance: false)

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(@partition, %{query: "unproven derived canary"}))

    assert {:ok, []} = Channels.fts(plan, 10)
  end

  test "FTS fails closed for session-only evidence without canonical subject identity" do
    memory = memory("session provenance canary", @partition, provenance: false)
    event_id = Ecto.UUID.generate()
    observation(event_id, @partition, "canonical session event", "evidence-session")

    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: memory.id,
        source_session_id: "evidence-session",
        host_id: @partition.host_id,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(@partition, %{query: "session provenance canary"}))

    assert {:ok, []} = Channels.fts(plan, 10)
  end

  test "FTS normalizes partition-enriched summaries with durable source events" do
    now = DateTime.utc_now()
    event_id = Ecto.UUID.generate()
    insert_event(event_id, @partition, "session-summary")

    repo().insert!(%ProjectedSession{
      subject_id: "subject-summary",
      session_id: "session-summary",
      project: "backplane",
      host_id: @partition.host_id,
      client_id: @partition.client_id,
      scope: @partition.scope,
      namespace: @partition.namespace,
      status: "closed",
      last_event_at: now,
      processing_version: "v1",
      input_revision: "r1"
    })

    summary =
      repo().insert!(
        Summary.changeset(
          %Summary{},
          summary_attrs(@partition, "session-summary", "weighted fusion summary")
        )
      )

    repo().insert!(%SourceEvent{
      summary_id: summary.id,
      event_id: event_id,
      host_id: @partition.host_id,
      session_id: "session-summary",
      inserted_at: DateTime.utc_now()
    })

    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{query: "weighted fusion", project: "backplane"})
             )

    assert {:ok, rows} = Channels.fts(plan, 10)

    assert Enum.any?(rows, fn {candidate, _score} ->
             candidate.kind == :summary and candidate.id == summary.id and
               candidate.source_ids == [event_id] and
               candidate.source_refs == [%{type: :event, id: event_id}]
           end)
  end

  test "FTS cannot launder a same-host summary through a colliding cross-partition session" do
    now = DateTime.utc_now()

    victim = %{
      host_id: @partition.host_id,
      client_id: "client-victim",
      scope: "personal",
      namespace: "private"
    }

    repo().insert!(%ProjectedSession{
      subject_id: "subject-attacker",
      session_id: "shared-session",
      project: "backplane",
      host_id: @partition.host_id,
      client_id: @partition.client_id,
      scope: @partition.scope,
      namespace: @partition.namespace,
      status: "closed",
      last_event_at: now,
      processing_version: "v1",
      input_revision: "attacker-r1"
    })

    repo().insert!(
      Summary.changeset(
        %Summary{},
        summary_attrs(victim, "shared-session", "private collision canary")
        |> Map.put(:subject_id, "subject-victim")
      )
    )

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(@partition, %{query: "private collision canary"}))

    assert {:ok, []} = Channels.fts(plan, 10)
  end

  test "FTS drops summary event refs from every same-host foreign partition dimension" do
    now = DateTime.utc_now()

    for {label, foreign} <- [
          {"client", %{@partition | client_id: "other-client"}},
          {"scope", %{@partition | scope: "personal"}},
          {"namespace", %{@partition | namespace: "other-namespace"}}
        ] do
      subject_id = "subject-local-refs-#{label}"
      session_id = "session-local-refs-#{label}"

      repo().insert!(%ProjectedSession{
        subject_id: subject_id,
        session_id: session_id,
        project: "backplane",
        host_id: @partition.host_id,
        client_id: @partition.client_id,
        scope: @partition.scope,
        namespace: @partition.namespace,
        status: "closed",
        last_event_at: now,
        processing_version: "v1",
        input_revision: "local-r1"
      })

      event_id = Ecto.UUID.generate()
      insert_event(event_id, foreign, session_id)

      summary =
        repo().insert!(
          Summary.changeset(
            %Summary{},
            summary_attrs(
              @partition,
              session_id,
              "foreign provenance #{label} canary"
            )
            |> Map.put(:subject_id, subject_id)
          )
        )

      repo().insert!(%SourceEvent{
        summary_id: summary.id,
        event_id: event_id,
        host_id: @partition.host_id,
        session_id: session_id,
        inserted_at: now
      })

      assert {:ok, plan} =
               QueryPlan.new(
                 Map.merge(@partition, %{query: "foreign provenance #{label} canary"})
               )

      assert {:ok, rows} = Channels.fts(plan, 10)
      refute Enum.any?(rows, fn {candidate, _score} -> candidate.id == summary.id end)
    end
  end

  test "vector applies exact partition before distance limit and never writes access state" do
    query_vector = vec(%{0 => 1.0})
    wanted = memory("vector wanted", @partition) |> embed(query_vector)

    for index <- 1..8 do
      memory("vector foreign #{index}", @foreign) |> embed(query_vector)
    end

    {:ok, plan} = QueryPlan.new(Map.merge(@partition, %{query: "vector"}))
    embed_fn = fn ["vector"], :query, [] -> {:ok, [query_vector]} end

    assert {:ok, [{candidate, score}]} = Channels.vector(plan, 1, embed_fn)
    assert candidate.id == wanted.id
    assert score > 0.99
    assert repo().get!(Memory, wanted.id).access_count == 0
  end

  test "graph is entity-hint driven, bounded, and resolves only exact-partition observations" do
    wanted_event = Ecto.UUID.generate()
    foreign_event = Ecto.UUID.generate()
    wanted = observation(wanted_event, @partition, "graph result")
    _foreign = observation(foreign_event, @foreign, "foreign graph result")

    repo().insert!(
      Node.changeset(
        %Node{},
        Map.merge(@partition, %{
          type: "Concept",
          name: "Backplane",
          source_observation_ids: [wanted_event]
        })
      )
    )

    repo().insert!(
      Node.changeset(
        %Node{},
        Map.merge(@foreign, %{
          type: "Concept",
          name: "Backplane",
          source_observation_ids: [foreign_event]
        })
      )
    )

    {:ok, no_hint} =
      QueryPlan.new(Map.merge(@partition, %{query: "graph", include_working: true}))

    assert {:unavailable, :no_entity_hints} = Channels.graph(no_hint, 10)

    {:ok, plan} =
      QueryPlan.new(
        Map.merge(@partition, %{
          query: "graph",
          entity_hints: ["Backplane"],
          include_working: true
        })
      )

    assert {:ok, [{candidate, score}]} = Channels.graph(plan, 1)
    assert candidate.id == wanted.event_id
    assert candidate.kind == :observation
    assert candidate.source_refs == [%{type: :event, id: wanted_event}]
    assert score == 1.0
  end

  test "graph worker writes truthful projected event provenance consumed by recall" do
    session_id = "writer-session"
    event_id = Ecto.UUID.generate()
    insert_event(event_id, @partition, session_id)
    observation(event_id, @partition, "writer event", session_id)
    linked = memory("writer memory linked", @partition, session_id: session_id, provenance: false)

    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: linked.id,
        source_event_id: event_id,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )

    for index <- 1..2 do
      memory("writer memory #{index}", @partition, session_id: session_id)
    end

    previous = Application.get_env(:backplane_memory, :llm_module)
    Application.put_env(:backplane_memory, :llm_module, GraphLLM)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :llm_module, previous),
        else: Application.delete_env(:backplane_memory, :llm_module)
    end)

    args =
      @partition
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("session_id", session_id)

    assert {:ok, %{nodes_extracted: 1}} = GraphExtractWorker.perform(%Oban.Job{args: args})

    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{
                 query: "graph",
                 entity_hints: ["WriterBackplane"]
               })
             )

    assert {:ok, [{candidate, 1.0}]} = Channels.graph(plan, 10)
    assert candidate.id == linked.id
    assert candidate.source_ids == [event_id]
    assert candidate.source_refs == [%{type: :event, id: event_id}]
  end

  test "graph cannot rank a local memory through a foreign event ID on a local node" do
    foreign_event = Ecto.UUID.generate()
    insert_event(foreign_event, @foreign, "foreign-graph-session")
    local = memory("local memory with forged graph evidence", @partition)

    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: local.id,
        source_event_id: foreign_event,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )

    repo().insert!(
      Node.changeset(
        %Node{},
        Map.merge(@partition, %{
          type: "Concept",
          name: "ForgedForeignGraph",
          source_observation_ids: [foreign_event]
        })
      )
    )

    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{
                 query: "graph",
                 entity_hints: ["ForgedForeignGraph"]
               })
             )

    assert {:ok, []} = Channels.graph(plan, 10)
  end

  test "working memory and observation channels are excluded by default" do
    memory("working exclusion canary", @partition, type: "working")

    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{
                 query: "working exclusion canary",
                 entity_hints: ["Backplane"]
               })
             )

    assert {:ok, []} = Channels.fts(plan, 10)
    assert {:unavailable, :no_graph_data} = Channels.graph(plan, 10)
  end

  test "all channel limits are strict and reject invalid bounds" do
    {:ok, plan} = QueryPlan.new(Map.merge(@partition, %{query: "q", entity_hints: ["q"]}))
    assert {:error, :invalid_limit} = Channels.fts(plan, 0)

    assert {:error, :invalid_limit} =
             Channels.vector(plan, 501, fn _, _, _ -> {:ok, [vec(%{})]} end)

    assert {:error, :invalid_limit} = Channels.graph(plan, 501)
  end

  defp memory(content, partition, opts \\ []) do
    memory =
      repo().insert!(
        Memory.changeset(%Memory{}, %{
          content: content,
          memory_type: Keyword.get(opts, :type, "semantic"),
          agent_id: "agent",
          host_id: partition.host_id,
          client_id: partition.client_id,
          scope: partition.scope,
          namespace: partition.namespace,
          session_id:
            Keyword.get(opts, :session_id, "session-#{System.unique_integer([:positive])}"),
          metadata: %{"project" => Keyword.get(opts, :project, "")}
        })
      )

    if Keyword.get(opts, :provenance, true), do: add_request_evidence(memory)
    memory
  end

  defp add_request_evidence(memory) do
    unique = Integer.to_string(System.unique_integer([:positive]))

    request =
      repo().insert!(
        RememberRequest.changeset(%RememberRequest{}, %{
          idempotency_scope: "recall-test",
          idempotency_key: unique,
          request_hash: :crypto.hash(:sha256, unique),
          memory_id: memory.id
        })
      )

    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: memory.id,
        source_request_id: request.id,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )
  end

  defp embed(memory, vector), do: repo().update!(Memory.embed_changeset(memory, vector))
  defp vec(positions), do: for(index <- 0..(@dim - 1), do: Map.get(positions, index, 0.0))

  defp observation(event_id, partition, content, session_id \\ nil) do
    repo().insert!(%ProjectedObservation{
      event_id: event_id,
      subject_id: "subject-#{event_id}",
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: session_id || "session-#{event_id}",
      project: "backplane",
      event_type: "agent.prompt.submitted",
      occurred_at: DateTime.utc_now(),
      content: content,
      message: content,
      importance: 1,
      is_error: false,
      file_paths: [],
      processing_version: "v1",
      input_revision: "r1"
    })
  end

  defp insert_event(id, partition, session_id) do
    repo().insert!(
      Stream.changeset(%Stream{}, %{
        stream_id: "stream-#{id}",
        project: "backplane",
        host_id: partition.host_id,
        client_id: partition.client_id,
        session_id: session_id
      })
    )

    repo().insert!(%Event{
      id: id,
      stream_id: "stream-#{id}",
      sequence: 1,
      project: "backplane",
      namespace: partition.namespace,
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      session_id: session_id,
      event_type: "agent.prompt.submitted",
      importance: 1,
      payload: %{},
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now()
    })
  end

  defp summary_attrs(partition, session_id, content),
    do: %{
      session_id: session_id,
      project: "backplane",
      content: content,
      subject_id: "subject-summary",
      host_id: partition.host_id,
      processing_version: "v1",
      input_revision: "i1",
      output_revision: "o1"
    }
end
