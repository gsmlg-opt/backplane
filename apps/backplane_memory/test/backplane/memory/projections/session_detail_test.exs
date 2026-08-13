defmodule Backplane.Memory.Projections.SessionDetailTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Projections.{Rebuild, SessionDetail, State}
  alias Backplane.Memory.Summaries.Summary

  import Backplane.Memory.IngestFixtures

  test "returns the complete bounded SES-002 representation from canonical projections" do
    host_id = unique("detail-host")
    session_id = unique("detail-session")
    child_session_id = unique("detail-child")
    project = unique("detail-project")
    partition = partition(host_id)
    started_at = ~U[2026-08-12 10:00:00.000000Z]

    started =
      event(
        host_id,
        session_id,
        project,
        1,
        "agent.session.started",
        %{
          "source" => %{"model" => "gpt-5", "prompt" => "Build session detail"}
        },
        started_at
      )
      |> Map.put("integration", "codex")
      |> Map.put("parent_session_id", "source-session")

    tool =
      event(
        host_id,
        session_id,
        project,
        2,
        "agent.tool.completed",
        %{
          "source" => %{
            "tool_name" => "Write",
            "tool_response" => "updated",
            "file_path" => "lib/session_detail.ex",
            "commit_hash" => "abc123"
          }
        },
        DateTime.add(started_at, 2, :second)
      )
      |> Map.put("importance", 8)

    ended =
      event(
        host_id,
        session_id,
        project,
        3,
        "agent.session.ended",
        %{},
        DateTime.add(started_at, 5, :second)
      )

    Enum.each([started, tool, ended], &ingest!/1)

    ingest!(
      event(
        host_id,
        child_session_id,
        project,
        1,
        "agent.session.started",
        %{},
        DateTime.add(started_at, 6, :second)
      )
      |> Map.put("parent_session_id", session_id)
    )

    assert {:ok, rebuilt} = Rebuild.session(host_id, session_id)
    assert {:ok, _child} = Rebuild.session(host_id, child_session_id)

    memory =
      %Memory{}
      |> Memory.changeset(%{
        content: "Session memory",
        memory_type: "semantic",
        host_id: host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        agent_id: "agent-1",
        session_id: session_id
      })
      |> repo().insert!()

    lesson =
      %Lesson{}
      |> Lesson.changeset(%{memory_id: memory.id, status: "active", source_kind: "manual"})
      |> repo().insert!()

    action =
      %Action{}
      |> Action.changeset(%{
        title: "Follow up",
        host_id: host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        project: project,
        source_observation_ids: [tool["event_id"]],
        created_at: started_at,
        updated_at: started_at
      })
      |> repo().insert!()

    crystal =
      %Crystal{}
      |> Crystal.changeset(%{
        memory_id: memory.id,
        subject_id: rebuilt.subject_id,
        host_id: host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        source_session_id: session_id,
        title: "Completed work",
        project: project,
        narrative: "Implemented the session detail",
        processing_version: "crystal-v1",
        prompt_version: "prompt-v1",
        input_revision: rebuilt.input_revision,
        output_revision: String.duplicate("c", 64),
        status: "complete"
      })
      |> repo().insert!()

    summary =
      %Summary{}
      |> Summary.changeset(%{
        session_id: session_id,
        project: project,
        content: "Implemented full session detail",
        observation_count: 3,
        subject_id: rebuilt.subject_id,
        host_id: host_id,
        agent_id: "agent-1",
        processing_version: "summary-v1",
        input_revision: rebuilt.input_revision,
        output_revision: "summary-output"
      })
      |> repo().insert!()

    repo().insert!(%State{
      projector: "summary",
      subject_type: "captured_session",
      subject_id: rebuilt.subject_id,
      processing_version: "summary-v1",
      input_revision: rebuilt.input_revision,
      output_revision: "summary-output",
      status: "complete",
      attempt_count: 1
    })

    assert {:ok, detail} = SessionDetail.get(partition, session_id)

    assert %{
             session_id: ^session_id,
             project: ^project,
             host_id: ^host_id,
             agent_id: "agent-1",
             integration: "codex",
             model: "gpt-5",
             status: "completed",
             first_prompt: "Build session detail",
             summary: %{id: summary_id, content: "Implemented full session detail"},
             observation_count: 3,
             event_type_breakdown: %{
               "agent.session.started" => 1,
               "agent.tool.completed" => 1,
               "agent.session.ended" => 1
             },
             tool_breakdown: %{"Write" => 1},
             files: ["lib/session_detail.ex"],
             commits: ["abc123"],
             source_session_id: "source-session",
             child_session_ids: [^child_session_id],
             processing: processing,
             links: links
           } = detail

    assert summary_id == summary.id
    assert detail.started_at == started_at
    assert detail.ended_at == DateTime.add(started_at, 5, :second)
    assert detail.duration_ms == 5_000
    assert processing.summary.status == "complete"
    assert processing.summary.last_error == nil

    assert Map.keys(processing) |> Enum.sort() ==
             ~w(crystal embeddings graph lessons profile summary)a

    assert [%{id: memory_id}] = links.memories
    assert [%{memory_id: lesson_memory_id}] = links.lessons
    assert [%{id: action_id}] = links.actions
    assert [%{id: crystal_id}] = links.crystals

    assert {memory_id, lesson_memory_id, action_id, crystal_id} ==
             {memory.id, lesson.memory_id, action.id, crystal.id}
  end

  test "requires one exact partition and does not cross hosts with a shared session id" do
    session_id = unique("shared-detail")
    project = unique("detail-project")

    for host_id <- ["detail-host-a", "detail-host-b"] do
      ingest!(
        event(
          host_id,
          session_id,
          project,
          1,
          "agent.session.started",
          %{},
          ~U[2026-08-12 10:00:00.000000Z]
        )
      )

      assert {:ok, _} = Rebuild.session(host_id, session_id)
    end

    assert {:ok, %{host_id: "detail-host-a"}} =
             SessionDetail.get(partition("detail-host-a"), session_id)

    assert {:error, :partition_required} = SessionDetail.get(%{}, session_id)
    assert {:error, :not_found} = SessionDetail.get(partition("missing-host"), session_id)
  end

  defp partition(host_id) do
    %{
      host_id: host_id,
      client_id: "host:#{host_id}",
      scope: "project:backplane",
      namespace: "private"
    }
  end

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp event(host_id, session_id, project, sequence, event_type, payload, occurred_at) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "agent_id" => "agent-1",
      "session_id" => session_id,
      "project" => project,
      "sequence" => sequence,
      "event_type" => event_type,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "captured_at" => DateTime.to_iso8601(occurred_at),
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{event_type}",
      "payload" => payload,
      "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
    })
  end

  defp ingest!(event) do
    auth = %{
      host_id: event["host_id"],
      auth_token_id: "token-#{event["host_id"]}",
      scopes: ["host_agent.capture"]
    }

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end
end
