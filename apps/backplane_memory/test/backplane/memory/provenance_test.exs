defmodule Backplane.Memory.ProvenanceTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures
  alias Backplane.Memory.{Ingest, Memories, Provenance}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Ingest.EventValidator
  alias Backplane.Memory.Memories.Memory

  alias Backplane.Memory.Projections.{
    Rebuild,
    SessionProjector,
    ObservationProjector,
    ReplayProjector
  }

  alias Backplane.Memory.Recall.{Channels, QueryPlan}
  alias Backplane.Memory.Summaries.{Summary, SourceEvent}

  test "capture upload preserves canonical identity and new repository sources without changing historical paths or retry ACKs" do
    event =
      capture(
        "provenance-host",
        "one",
        1,
        "https://user:secret@git.example/org/repo.git",
        "/one/sub"
      )

    saved = ingest!(event)
    assert saved.host_id == "provenance-host"
    assert saved.project == "/one/sub"
    assert saved.raw_envelope["host_id"] == "provenance-host"

    assert [%{"repository_id" => "git.example/org/repo", "cwd" => "/one/sub"}] =
             saved.payload["repository_sources"]

    refute inspect(saved.payload) =~ "secret"

    assert {:ok, %{"results" => [%{"status" => "duplicate", "server_event_id" => id}]}} =
             ingest(event)

    assert id == saved.id

    old = capture("provenance-host", "historical", 1, nil, "/historical/path")
    payload = Map.delete(old["payload"], "repository_sources")

    old =
      old
      |> Map.put("payload", payload)
      |> Map.put("payload_hash", EventValidator.payload_hash(payload))

    historical = ingest!(old)
    assert Map.delete(historical.payload, "_backplane") == payload
    assert historical.payload_hash == old["payload_hash"]
    refute Map.has_key?(historical.payload, "repository_sources")

    forged = event |> Map.put("event_id", Ecto.UUID.generate()) |> Map.put("host_id", "forged")
    assert {:ok, %{"results" => [%{"status" => "rejected"}]}} = ingest(forged, "provenance-host")
  end

  test "multi-repository summary evidence reaches derived memories and recall while foreign canonical sources cannot leak" do
    first =
      ingest!(
        capture("provenance-host", "derived", 1, "git@git.example:org/repo.git", "/one/sub")
      )

    second =
      ingest!(
        capture("provenance-host", "derived", 2, "https://git.example/fork/repo", "/two")
        |> Map.put("project", first.project)
      )

    foreign =
      ingest!(
        capture("other-host", "derived", 1, "https://foreign.example/private/repo", "/foreign")
      )

    partition = partition("provenance-host")
    assert {:ok, _} = Rebuild.session("provenance-host", "derived")
    now = DateTime.utc_now()

    summary =
      repo().insert!(
        Summary.changeset(
          %Summary{},
          Map.merge(partition, %{
            session_id: "derived",
            project: "/historical/summary/path",
            content: "traceable repository fact",
            subject_id:
              Backplane.Memory.Projections.Source.subject_id!("provenance-host", "derived"),
            processing_version: "summary-test",
            input_revision: String.duplicate("a", 64),
            output_revision: String.duplicate("b", 64)
          })
        )
      )

    repo().insert_all(
      SourceEvent,
      Enum.map(
        [first, second],
        &%{
          summary_id: summary.id,
          event_id: &1.id,
          host_id: &1.host_id,
          session_id: "derived",
          inserted_at: now
        }
      )
    )

    evidence = [
      %{
        source_summary_id: summary.id,
        host_id: partition.host_id,
        evidence_kind: "derives",
        support_score: 1.0
      }
    ]

    opts =
      Map.to_list(partition) ++
        [
          agent_id: "test",
          metadata: %{"project" => summary.project},
          evidence: evidence,
          idempotency_scope: "provenance",
          idempotency_key: "derived"
        ]

    assert {:ok, memory} = Memories.remember("traceable repository fact", opts)
    assert memory.metadata["project"] == summary.project

    assert Enum.map(memory.metadata["repository_sources"], & &1["repository_id"]) == [
             "git.example/fork/repo",
             "git.example/org/repo"
           ]

    assert {:ok, retry} = Memories.remember("traceable repository fact", opts)
    assert retry.id == memory.id

    assert Enum.any?(
             Memories.list_evidence(memory.id),
             &(&1.source_type == "summary" and &1.source_id == summary.id)
           )

    # A forged foreign reference cannot supply metadata even before the durable
    # evidence constraint rejects a write. The canonical tuple always wins.
    assert Provenance.metadata(%{}, [%{source_event_id: foreign.id}], partition) == %{}

    assert {:ok, plan} =
             QueryPlan.new(Map.merge(partition, %{query: "traceable repository fact"}))

    assert {:ok, candidates} = Channels.fts(plan, 20)

    candidate =
      Enum.find_value(candidates, fn {candidate, _} ->
        if candidate.id == memory.id, do: candidate
      end)

    assert candidate.repository_sources == memory.metadata["repository_sources"]
    assert candidate.source_host_id == partition.host_id
    assert candidate.project == summary.project

    summary_candidate =
      Enum.find_value(candidates, fn {candidate, _} ->
        if candidate.kind == :summary, do: candidate
      end)

    assert summary_candidate.repository_sources == memory.metadata["repository_sources"]
    assert summary_candidate.source_host_id == partition.host_id

    before = repo().get!(Memory, memory.id)
    assert :ok = Memories.forget(memory.id, partition)
    deleted = repo().get!(Memory, memory.id)
    assert deleted.content == before.content
    assert deleted.metadata == before.metadata
    assert deleted.inserted_at == before.inserted_at
    assert deleted.deleted_at
  end

  test "reused memories union source associations without churn and preserve tombstones" do
    partition = partition("union-host")
    base = Map.to_list(partition) ++ [agent_id: "test", idempotency_scope: "provenance-union"]

    first_source = %{
      "repository_id" => "git.example/one/repo",
      "checkout_root" => "/one",
      "cwd" => "/one"
    }

    second_source = %{
      "repository_id" => "git.example/two/repo",
      "checkout_root" => "/two",
      "cwd" => "/two"
    }

    metadata = %{
      "project" => "/historical",
      "unrelated" => "retain",
      "repository_sources" => [first_source]
    }

    assert {:ok, first} =
             Memories.remember(
               "same durable source fact",
               base ++ [metadata: metadata, idempotency_key: "one"]
             )

    assert {:ok, merged} =
             Memories.remember(
               "same durable source fact",
               base ++
                 [
                   metadata: %{metadata | "repository_sources" => [second_source]},
                   idempotency_key: "two"
                 ]
             )

    assert merged.id == first.id

    assert merged.metadata["repository_sources"] ==
             Backplane.MemoryRepository.sources([first_source, second_source])

    assert merged.metadata["unrelated"] == "retain"
    assert merged.metadata["project"] == "/historical"
    assert merged.content == first.content
    assert merged.inserted_at == first.inserted_at

    assert {:ok, repeat} =
             Memories.remember(
               "same durable source fact",
               base ++
                 [
                   metadata: %{metadata | "repository_sources" => [second_source]},
                   idempotency_key: "three"
                 ]
             )

    assert repeat.updated_at == merged.updated_at
    assert :ok = Memories.forget(first.id, partition)
    tombstone = repo().get!(Memory, first.id)
    assert tombstone.metadata == repeat.metadata
    assert tombstone.deleted_at
  end

  test "pure session, observation and replay projections retain a union of source associations" do
    first =
      ingest!(capture("projection-host", "projected", 1, "https://git.example/org/repo", "/one"))

    second =
      ingest!(
        capture("projection-host", "projected", 2, "git@git.example:org/repo.git", "/worktree")
        |> Map.put("project", first.project)
      )

    events = [first, second]
    assert length(SessionProjector.project(events, [])["repository_sources"]) == 2
    projected = ObservationProjector.project(events)
    assert length(projected["repository_sources"]) == 2
    assert Enum.all?(projected["observations"], &(length(&1["repository_sources"]) == 1))

    assert Enum.all?(
             ReplayProjector.project(events),
             &(length(&1["detail"]["repository_sources"]) == 1)
           )

    assert {:ok, _} = Rebuild.session("projection-host", "projected")
  end

  test "malformed historical repository metadata cannot break compatible projection reads" do
    for bad <- ["historical-project-string", %{"unexpected" => true}, [nil, 1, "invalid"], nil] do
      assert Provenance.event_sources([%{payload: %{"repository_sources" => bad}}]) == []
    end
  end

  defp partition(host) do
    %{
      memory_space_id: ensure_memory_space!(host),
      host_id: host,
      client_id: "host:#{host}",
      scope: "proj_local",
      namespace: "private"
    }
  end

  defp capture(host, session, sequence, remote, cwd) do
    valid_event(%{
      "host_id" => host,
      "session_id" => session,
      "sequence" => sequence,
      "project" => cwd,
      "idempotency_key" => "#{host}:#{session}:#{sequence}",
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "payload" => %{
        "message" => "traceable repository fact",
        "repository_sources" => [
          %{"repository_id" => remote, "cwd" => cwd, "checkout_root" => cwd}
        ]
      }
    })
  end

  defp ingest(event, auth_host \\ nil) do
    host = auth_host || event["host_id"]

    Ingest.ingest_batch(ingest_auth_context(host), %{
      "batch_id" => Ecto.UUID.generate(),
      "host_id" => host,
      "events" => [event]
    })
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             ingest(event)

    repo().get!(Event, id)
  end
end
