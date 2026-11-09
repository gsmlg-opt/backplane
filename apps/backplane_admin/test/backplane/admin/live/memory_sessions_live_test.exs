defmodule Backplane.Admin.MemorySessionsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Distillation
  alias Backplane.Memory.Projections.ProjectedSession

  defp seed_failed(error) do
    now = DateTime.utc_now()
    subject_id = "subj-#{System.unique_integer([:positive])}"

    Backplane.Repo.insert!(%ProjectedSession{
      subject_id: subject_id,
      host_id: "host-1",
      session_id: "sess-#{subject_id}",
      agent_id: "agent-1",
      status: "completed",
      processing_version: "1",
      input_revision: "r1",
      started_at: now,
      ended_at: DateTime.add(now, 60),
      last_event_at: now,
      inserted_at: now,
      updated_at: now
    })

    Backplane.Repo.insert!(%Distillation{
      subject_id: subject_id,
      host_id: "host-1",
      session_id: "sess-#{subject_id}",
      status: "failed",
      mode: "distill",
      last_error: error,
      due_at: now,
      inserted_at: now,
      updated_at: now
    })

    subject_id
  end

  test "failed distillation shows its error and Retry sets it pending", %{conn: conn} do
    subject_id = seed_failed("model rejected tools")
    {:ok, view, _} = live_with_sandbox(conn, "/memory/sessions")

    assert has_element?(view, "#distill-status-#{subject_id}", "failed")
    assert has_element?(view, "#distill-error-#{subject_id}", "model rejected tools")

    view |> element("#distill-retry-#{subject_id}") |> render_click()

    assert Backplane.Repo.get!(Distillation, subject_id).status == "pending"
    assert has_element?(view, "#distill-status-#{subject_id}", "pending")
    refute has_element?(view, "#distill-retry-#{subject_id}")
  end
end
