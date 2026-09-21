defmodule Backplane.Memory.Workers.CrystalWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Crystals.ProjectionStore
  alias Backplane.Memory.Projections.{Source, State}

  test "records a precise no-model terminal state for crystallization" do
    partition = canonical_partition("crystal-processing-state")
    session_id = "session-#{System.unique_integer([:positive])}"
    subject_id = Source.subject_id!(partition.host_id, session_id)
    revision = String.duplicate("a", 64)

    repo().insert!(
      State.changeset(%State{}, %{
        memory_space_id: partition.memory_space_id,
        host_id: partition.host_id,
        source_client_id: partition.source_client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        projector: "crystal",
        subject_type: "captured_session",
        subject_id: subject_id,
        processing_version: "crystal-v1",
        input_revision: revision,
        status: "running",
        attempt_count: 1
      })
    )

    assert {:ok, %State{status: "skipped_no_model", last_error: "no_llm"}} =
             ProjectionStore.skipped(partition.host_id, session_id, revision, :no_llm)
  end

  test "records retryable failure before dead-lettering the final attempt" do
    partition = canonical_partition("crystal-dead-letter")
    session_id = "session-#{System.unique_integer([:positive])}"
    subject_id = Source.subject_id!(partition.host_id, session_id)
    revision = String.duplicate("b", 64)

    repo().insert!(
      State.changeset(%State{}, %{
        memory_space_id: partition.memory_space_id,
        host_id: partition.host_id,
        source_client_id: partition.source_client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        projector: "crystal",
        subject_type: "captured_session",
        subject_id: subject_id,
        processing_version: "crystal-v1",
        input_revision: revision,
        status: "running",
        attempt_count: 1
      })
    )

    assert {:ok, %State{status: "failed"}} =
             ProjectionStore.failed(
               partition.host_id,
               session_id,
               revision,
               :llm_unavailable,
               false
             )

    assert {:ok, %State{status: "dead_letter"}} =
             ProjectionStore.failed(
               partition.host_id,
               session_id,
               revision,
               :llm_unavailable,
               true
             )
  end
end
