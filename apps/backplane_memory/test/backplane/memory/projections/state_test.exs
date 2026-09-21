defmodule Backplane.Memory.Projections.StateTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Projections.{ProcessingState, Snapshot, State}

  defmodule LockOrderRepo do
    def transaction(fun), do: {:ok, fun.()}

    def one(_query) do
      send(self(), :state_locked)
      %State{input_revision: String.duplicate("b", 64)}
    end
  end

  @subject %{
    memory_space_id: "00000000-0000-4000-8000-000000000001",
    scope: "global",
    namespace: "private",
    projector: "session",
    subject_type: "captured_session",
    subject_id: "host-1/session-1",
    processing_version: "session-v1"
  }

  test "state accepts every precise processing status and rejects generic skipped" do
    assert State.statuses() ==
             ~w(pending enqueued running complete skipped_no_model skipped_disabled failed dead_letter)

    for status <- State.statuses() do
      assert State.changeset(%State{}, Map.put(@subject, :status, status)).valid?
    end

    refute State.changeset(%State{}, Map.put(@subject, :status, "skipped")).valid?
    refute State.changeset(%State{}, Map.put(@subject, :status, "queued")).valid?
  end

  test "state requires a non-negative attempt count" do
    refute State.changeset(%State{}, Map.put(@subject, :attempt_count, -1)).valid?
    assert State.changeset(%State{}, Map.put(@subject, :attempt_count, 0)).valid?
  end

  test "persists each precise processing transition and rejects generic skipped" do
    partition = canonical_partition("projection-state")

    attrs =
      @subject
      |> Map.merge(partition)
      |> Map.put(:input_revision, String.duplicate("a", 64))

    for status <- State.statuses() do
      assert {:ok, %State{status: ^status}} = ProcessingState.transition(repo(), attrs, status)
    end

    assert_raise FunctionClauseError, fn ->
      ProcessingState.transition(repo(), attrs, "skipped")
    end
  end

  test "a newer revision replaces active state while late terminal writes stay stale" do
    partition = canonical_partition("projection-state-revision")

    attrs =
      @subject |> Map.merge(partition) |> Map.put(:input_revision, String.duplicate("a", 64))

    newer = Map.put(attrs, :input_revision, String.duplicate("b", 64))
    old_revision = attrs.input_revision
    new_revision = newer.input_revision

    assert {:ok, %State{input_revision: ^old_revision, status: "running"}} =
             ProcessingState.transition(repo(), attrs, "running")

    assert {:ok, %State{input_revision: ^new_revision, status: "running"}} =
             ProcessingState.transition(repo(), newer, "running", authoritative_revision: true)

    assert {:stale, %State{input_revision: ^new_revision}} =
             ProcessingState.transition(repo(), attrs, "running")

    assert {:stale, %State{input_revision: ^new_revision}} =
             ProcessingState.transition(repo(), attrs, "complete")
  end

  test "transition_current permits current revisions and rejects a stale snapshot" do
    partition = canonical_partition("projection-state-current")
    old = @subject |> Map.merge(partition) |> Map.put(:input_revision, String.duplicate("a", 64))
    current = Map.put(old, :input_revision, String.duplicate("b", 64))

    assert {:ok, %State{input_revision: old_revision}} =
             ProcessingState.transition_current(repo(), old, "running", fn -> {:ok, old} end)

    assert old_revision == old.input_revision

    assert {:ok, %State{input_revision: current_revision}} =
             ProcessingState.transition_current(repo(), current, "running", fn ->
               {:ok, current}
             end)

    assert current_revision == current.input_revision

    assert {:stale, %State{input_revision: ^current_revision}} =
             ProcessingState.transition_current(repo(), old, "complete", fn -> {:ok, current} end)
  end

  test "current authority is fenced before projection state is locked" do
    attrs = Map.put(@subject, :input_revision, String.duplicate("a", 64))
    current = Map.put(attrs, :input_revision, String.duplicate("b", 64))

    current_attrs = fn ->
      send(self(), :authority_fenced)
      {:ok, current}
    end

    assert {:stale, %State{}} =
             ProcessingState.transition_current(
               LockOrderRepo,
               attrs,
               "complete",
               current_attrs
             )

    assert_receive :authority_fenced
    assert_receive :state_locked

    assert {:stale, %State{}} =
             ProcessingState.persist_current(
               LockOrderRepo,
               attrs,
               current_attrs,
               fn -> flunk("stale persistence callback must not run") end
             )

    assert_receive :authority_fenced
    assert_receive :state_locked
  end

  test "persist_current rejects stale authority without invoking persistence" do
    partition = canonical_partition("projection-state-persist-stale")
    old = @subject |> Map.merge(partition) |> Map.put(:input_revision, String.duplicate("a", 64))
    current = Map.put(old, :input_revision, String.duplicate("b", 64))
    parent = self()

    assert {:ok, %State{}} = ProcessingState.transition(repo(), old, "running")

    assert {:stale, %State{}} =
             ProcessingState.persist_current(
               repo(),
               old,
               fn -> {:ok, current} end,
               fn ->
                 send(parent, :persisted)
                 {:ok, :written}
               end
             )

    refute_received :persisted
  end

  test "persist_current rolls back output when the persistence callback fails" do
    partition = canonical_partition("projection-state-persist-rollback")

    attrs =
      @subject
      |> Map.merge(partition)
      |> Map.put(:subject_id, "host-1/session-rollback")
      |> Map.put(:input_revision, String.duplicate("a", 64))

    snapshot_attrs =
      attrs
      |> Map.put(:output_revision, String.duplicate("b", 64))
      |> Map.put(:read_model, %{"events" => []})

    assert {:ok, %State{}} = ProcessingState.transition(repo(), attrs, "running")

    assert {:error, :write_failed} =
             ProcessingState.persist_current(
               repo(),
               attrs,
               fn -> {:ok, attrs} end,
               fn ->
                 snapshot_attrs
                 |> then(&Snapshot.changeset(%Snapshot{}, &1))
                 |> repo().insert!()

                 {:error, :write_failed}
               end
             )

    refute repo().get_by(Snapshot, subject_id: attrs.subject_id)
    assert %State{status: "running"} = repo().get_by!(State, subject_id: attrs.subject_id)
  end

  test "state requires a processing version" do
    refute State.changeset(%State{}, Map.delete(@subject, :processing_version)).valid?

    assert State.changeset(%State{}, @subject).valid?
  end

  test "snapshot requires deterministic input and output revisions" do
    attrs =
      Map.merge(@subject, %{
        input_revision: String.duplicate("a", 64),
        output_revision: String.duplicate("b", 64),
        read_model: %{"events" => []}
      })

    assert Snapshot.changeset(%Snapshot{}, attrs).valid?
    refute Snapshot.changeset(%Snapshot{}, Map.delete(attrs, :input_revision)).valid?
    refute Snapshot.changeset(%Snapshot{}, Map.delete(attrs, :output_revision)).valid?
  end
end
