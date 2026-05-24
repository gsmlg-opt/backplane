defmodule BackplaneMemory.Workers.FallbackSweepWorkerTest do
  use BackplaneMemory.DataCase

  alias BackplaneMemory.Workers.FallbackSweepWorker
  alias BackplaneMemory.Observations

  test "enqueues summary workers for orphaned sessions" do
    # Register a session, end it, but don't consolidate
    Observations.register_session("sess-orphan-1", "proj")
    Observations.end_session("sess-orphan-1")

    # Manually backdate ended_at to simulate old session
    repo = Application.fetch_env!(:backplane_memory, :repo)
    import Ecto.Query
    alias BackplaneMemory.Observations.Session

    repo.update_all(
      from(s in Session, where: s.session_id == "sess-orphan-1"),
      set: [ended_at: DateTime.add(DateTime.utc_now(), -7200, :second)]
    )

    # Also clear consolidated_at if set by end_session
    repo.update_all(
      from(s in Session, where: s.session_id == "sess-orphan-1"),
      set: [consolidated_at: nil]
    )

    result = FallbackSweepWorker.perform(%Oban.Job{args: %{}})
    assert {:ok, %{swept: n}} = result
    assert n >= 1
  end
end
