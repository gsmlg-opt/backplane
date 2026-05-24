defmodule BackplaneMemory.Workers.SummaryWorkerTest do
  use BackplaneMemory.DataCase

  alias BackplaneMemory.Workers.SummaryWorker
  alias BackplaneMemory.Consolidation.Summary
  alias BackplaneMemory.Observations

  test "creates a summary row for a session with observations" do
    Observations.register_session("sess-sum-1", "test-project")
    {:ok, _} = Observations.record("sess-sum-1", "def authenticate(user), do: ...", [])
    {:ok, _} = Observations.record("sess-sum-1", "JWT token validated with jose library", [])

    # Run the worker directly (do not call end_session, which also enqueues inline)
    assert :ok = SummaryWorker.perform(%Oban.Job{args: %{"session_id" => "sess-sum-1"}})

    repo = Application.fetch_env!(:backplane_memory, :repo)
    import Ecto.Query
    summary = repo.one(from(s in Summary, where: s.session_id == "sess-sum-1"))

    assert summary != nil
    assert summary.project == "test-project"
    assert summary.observation_count > 0
    assert String.contains?(summary.content, "sess-sum-1")
  end

  test "no-ops for unknown session" do
    assert :ok = SummaryWorker.perform(%Oban.Job{args: %{"session_id" => "no-such-session"}})
  end
end
