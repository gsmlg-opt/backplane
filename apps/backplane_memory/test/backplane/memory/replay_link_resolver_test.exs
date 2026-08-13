defmodule Backplane.Memory.ReplayLinkResolverTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.{Crystal, SourceEvent}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Replay
  alias Backplane.Memory.Summaries.Summary

  @partition %{
    host_id: "link-host",
    client_id: "link-client",
    scope: "link-scope",
    namespace: "private"
  }

  test "attaches distinct partition-owned derived links to their replay events" do
    session = "replay-links-#{System.unique_integer([:positive])}"
    first_event_id = append!(session, 1)
    second_event_id = append!(session, 2)
    assert {:ok, result} = Rebuild.session(@partition.host_id, session)

    summary = insert_summary!(result.subject_id, result.input_revision, session)
    first_memory = insert_memory!(session, "first")
    second_memory = insert_memory!(session, "second")

    insert_evidence!(first_memory.id, first_event_id, session)
    insert_evidence!(second_memory.id, second_event_id, session)

    lesson =
      repo().insert!(
        Lesson.changeset(%Lesson{}, %{
          memory_id: first_memory.id,
          status: "active",
          source_kind: "manual"
        })
      )

    graph =
      repo().insert!(
        Node.changeset(
          %Node{},
          Map.merge(@partition, %{
            type: "Concept",
            name: "Replay",
            source_observation_ids: [first_event_id]
          })
        )
      )

    foreign_graph =
      repo().insert!(
        Node.changeset(
          %Node{},
          @partition
          |> Map.put(:client_id, "foreign-client")
          |> Map.merge(%{
            type: "Concept",
            name: "Foreign replay",
            source_observation_ids: [first_event_id]
          })
        )
      )

    action =
      repo().insert!(
        Action.changeset(
          %Action{},
          Map.merge(@partition, %{
            title: "Follow up",
            source_observation_ids: [second_event_id]
          })
        )
      )

    crystal =
      insert_crystal!(second_memory.id, result.subject_id, result.input_revision, session)

    repo().insert!(%SourceEvent{
      crystal_id: crystal.id,
      event_id: second_event_id,
      inserted_at: DateTime.utc_now()
    })

    assert {:ok, %{events: [first, second]}} = Replay.load(@partition, session)
    assert first.event_id == first_event_id
    assert second.event_id == second_event_id
    assert first.links.summary == [summary.id]
    assert second.links.summary == [summary.id]
    assert first.links.memory == [first_memory.id]
    assert second.links.memory == [second_memory.id]
    assert first.links.lesson == [lesson.memory_id]
    assert second.links.lesson == []
    assert first.links.graph == [graph.id]
    refute foreign_graph.id in first.links.graph
    assert second.links.graph == []
    assert first.links.action == []
    assert second.links.action == [action.id]
    assert first.links.crystal == []
    assert second.links.crystal == [crystal.id]
  end

  defp insert_summary!(subject_id, input_revision, session) do
    repo().insert!(
      Summary.changeset(%Summary{}, %{
        subject_id: subject_id,
        host_id: @partition.host_id,
        session_id: session,
        content: "summary",
        processing_version: "summary-v1",
        input_revision: input_revision,
        output_revision: String.duplicate("b", 64)
      })
    )
  end

  defp insert_memory!(session, suffix) do
    repo().insert!(
      Memory.changeset(
        %Memory{},
        Map.merge(@partition, %{
          content: "linked memory #{session} #{suffix}",
          agent_id: "agent",
          session_id: session
        })
      )
    )
  end

  defp insert_evidence!(memory_id, event_id, session) do
    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: memory_id,
        source_event_id: event_id,
        session_id: session,
        host_id: @partition.host_id,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )
  end

  defp insert_crystal!(memory_id, subject_id, input_revision, session) do
    repo().insert!(
      Crystal.changeset(
        %Crystal{},
        Map.merge(@partition, %{
          memory_id: memory_id,
          subject_id: subject_id,
          source_session_id: session,
          title: "Crystal",
          narrative: "Narrative",
          processing_version: "crystal-v1",
          prompt_version: "prompt-v1",
          input_revision: input_revision,
          output_revision: String.duplicate("c", 64),
          status: "complete"
        })
      )
    )
  end

  defp append!(session, sequence) do
    event_id = Ecto.UUID.generate()

    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: event_id,
               stream_id: "capture:#{@partition.host_id}:#{session}",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: session,
               sequence: sequence,
               source_sequence: sequence,
               event_type: "agent.prompt.submitted",
               occurred_at: ~U[2026-08-12 00:00:00.000000Z],
               idempotency_key: "#{session}:#{sequence}",
               payload: %{"source" => %{"prompt" => "hello #{sequence}"}},
               payload_hash: "sha256:#{session}:#{sequence}",
               schema_version: 1
             })

    event_id
  end
end
