defmodule Backplane.Memory.Projections.StateTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Projections.{Snapshot, State}

  @subject %{
    projector: "session",
    subject_type: "captured_session",
    subject_id: "host-1/session-1",
    processing_version: "session-v1"
  }

  test "state accepts every designed status and rejects unknown statuses" do
    for status <- State.statuses() do
      assert State.changeset(%State{}, Map.put(@subject, :status, status)).valid?
    end

    refute State.changeset(%State{}, Map.put(@subject, :status, "queued")).valid?
  end

  test "state requires a non-negative attempt count" do
    refute State.changeset(%State{}, Map.put(@subject, :attempt_count, -1)).valid?
    assert State.changeset(%State{}, Map.put(@subject, :attempt_count, 0)).valid?
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
