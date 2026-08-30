defmodule Backplane.Memory.Projections.SummaryInputTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Projections.{ReadModels, Rebuild, Source, State}

  test "reads complete revision-aligned observations and errors in bounded importance order" do
    host_id = unique("summary-host")
    session_id = unique("summary-session")
    project = unique("summary-project")

    ingest!(event(host_id, session_id, project, 1, "agent.session.started", "start"))

    ingest!(
      event(host_id, session_id, project, 2, "agent.prompt.submitted", "short")
      |> Map.put("importance", 5)
    )

    ingest!(
      event(
        host_id,
        session_id,
        project,
        3,
        "agent.tool.completed",
        "the longest useful observation"
      )
      |> Map.put("importance", 9)
    )

    ingest!(
      event(
        host_id,
        session_id,
        project,
        4,
        "agent.tool.failed",
        "very long error that must be excluded"
      )
      |> Map.put("importance", 10)
    )

    ingest!(event(host_id, session_id, project, 5, "agent.session.ended", "done"))
    assert {:ok, rebuild} = Rebuild.session(host_id, session_id)

    repo().insert!(%Session{session_id: session_id, project: "legacy-decoy"})
    repo().insert!(%Observation{session_id: session_id, content: "legacy decoy is longest"})

    assert {:ok, input} = ReadModels.summary_input(host_id, session_id, limit: 3)
    assert input.subject_id == Source.subject_id!(host_id, session_id)
    assert input.input_revision == rebuild.input_revision
    assert input.project == project
    assert input.status == "completed"
    assert length(input.observations) == 3
    refute Map.has_key?(input, :source_event_ids)

    assert {:ok, {:ok, %{input_revision: streamed_revision, event_count: 5}}} =
             repo().transaction(fn -> Source.input_revision(host_id, session_id) end)

    assert streamed_revision == rebuild.input_revision

    assert Enum.map(input.observations, & &1.content) == [
             "the longest useful observation",
             "short",
             "start"
           ]

    refute inspect(input) =~ "legacy decoy"
    assert Enum.map(input.errors, & &1.content) == ["very long error that must be excluded"]

    assert {:error, :invalid_options} = ReadModels.summary_input(host_id, session_id, limit: 101)
    assert {:error, :invalid_host_id} = ReadModels.summary_input("", session_id)
  end

  test "refuses active, gapped, and revision-misaligned projections" do
    active = unique("active")
    ingest!(event("host-active", active, "p", 1, "agent.session.started", "start"))
    assert {:ok, _} = Rebuild.session("host-active", active)
    assert {:error, :session_not_closed} = ReadModels.summary_input("host-active", active)

    gapped = unique("gapped")
    ingest!(event("host-gap", gapped, "p", 1, "agent.session.started", "start"))
    ingest!(event("host-gap", gapped, "p", 3, "agent.session.ended", "done"))
    assert {:ok, _} = Rebuild.session("host-gap", gapped)
    assert {:error, :projection_incomplete} = ReadModels.summary_input("host-gap", gapped)

    closed = unique("misaligned")
    ingest!(event("host-misaligned", closed, "p", 1, "agent.session.started", "start"))
    ingest!(event("host-misaligned", closed, "p", 2, "agent.session.ended", "done"))
    assert {:ok, result} = Rebuild.session("host-misaligned", closed)

    subject_id = result.subject_id

    repo().update_all(
      from(s in State, where: s.projector == "observations" and s.subject_id == ^subject_id),
      set: [input_revision: String.duplicate("f", 64)]
    )

    assert {:error, :projection_incomplete} =
             ReadModels.summary_input("host-misaligned", closed)
  end

  defp event(host, session, project, sequence, type, content) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host,
      "session_id" => session,
      "project" => project,
      "sequence" => sequence,
      "event_type" => type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host}:#{session}:#{sequence}:#{type}",
      "payload" => %{"message" => content}
    })
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}}),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => event["host_id"],
                 "events" => [event]
               }
             )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
